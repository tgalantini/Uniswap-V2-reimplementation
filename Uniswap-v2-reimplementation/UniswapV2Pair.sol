// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title UniswapV2Pair modernized
/// @author Tommaso Galantini
/// @notice Can be used without a router or external contract
/// @dev swap, mint, and burn functions implement safety checks for the user, also flash loan functions has been added

import {ERC20} from "https://raw.githubusercontent.com/Vectorized/solady/7deab021af0426307ae79d091c4d1e26e9e89cf0/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "https://raw.githubusercontent.com/Vectorized/solady/7deab021af0426307ae79d091c4d1e26e9e89cf0/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";



contract UniswapV2Pair is ERC20, ReentrancyGuard, IERC3156FlashLender {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    // Immutable variables save gas when accessed
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast;

    // Constants
    uint256 public constant MINIMUM_LIQUIDITY = 10**3;
    uint256 public constant FEE_PERCENT = 3; // Represents 0.3% fee
    uint256 public constant FEE_DENOMINATOR = 1000;

    // EVENTS
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event Skim(address indexed to);
    event Mint(address indexed sender, uint256 amount0In, uint256 amount1In);
    event Burn(
        address indexed sender,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    //CUSTOM ERRORS
    error Forbidden();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientLiquidity();
    error InsufficientInputAmount();
    error WrongAmountUsage();
    error KInvariant();

    constructor(address _token0, address _token1) {
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
    }

    /// @notice Adds liquidity to the pool and mints liquidity tokens to the specified address.
    /// @dev Emits a Mint event.
    /// @dev Reverts if the amounts provided are insufficient or if the liquidity minted is zero.
    /// @param to The address to which the liquidity tokens will be minted.
    /// @param amount0Desired The desired amount of token0 to add as liquidity.
    /// @param amount1Desired The desired amount of token1 to add as liquidity.
    /// @param amount0Min The minimum amount of token0 to add as liquidity (slippage protection).
    /// @param amount1Min The minimum amount of token1 to add as liquidity (slippage protection).
    /// @return liquidity The amount of liquidity tokens minted.
    function mint(
        address to,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 liquidity) {

        {
            // avoid stack too deep
            // Checks for user's safety
            (uint256 amountA, uint256 amountB) = _addLiquidity(
                amount0Desired,
                amount1Desired,
                amount0Min,
                amount1Min
            );
            //Handles token transfers
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amountA);
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amountB);
        }

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        (uint112 _reserve0, uint112 _reserve1) = (reserve0, reserve1);
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            liquidity =
                FixedPointMathLib.sqrt(amount0 * amount1) -
                MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // Permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = FixedPointMathLib.min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );

        }

        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _mint(to, liquidity);
        _update(balance0, balance1, _reserve0, _reserve1);

        if (feeOn) kLast = uint256((reserve0) * (reserve1)); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Burns liquidity tokens and returns the underlying tokens to the specified address.
    /// @dev Emits a Burn event.
    /// @dev Reverts if the liquidity burned is insufficient or if the output amounts are less than minimums.
    /// @param to The address to which the underlying tokens will be sent.
    /// @param liquidityIn The amount of liquidity tokens to burn.
    /// @param amount0Min The minimum amount of token0 to receive (slippage protection).
    /// @param amount1Min The minimum amount of token1 to receive (slippage protection).
    /// @return amount0 The amount of token0 returned.
    /// @return amount1 The amount of token1 returned.
    function burn(
        address to,
        uint256 liquidityIn,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        // Transfers liquidity in from the user to perform the burn
        transferFrom(msg.sender, address(this), liquidityIn);
        (uint112 _reserve0, uint112 _reserve1) = (reserve0, reserve1);

        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        bool feeOn = _mintFee(_reserve0, _reserve1);
        {
            uint256 liquidity = balanceOf(address(this));
            uint256 _totalSupply = totalSupply();
            amount0 = (liquidity * balance0) / _totalSupply;
            amount1 = (liquidity * balance1) / _totalSupply;

            if (amount0 == 0 || amount1 == 0)
                revert InsufficientLiquidityBurned();
            if (amount0 < amount0Min || amount1 < amount1Min)
                revert InsufficientOutputAmount();

            _burn(address(this), liquidity);
        }
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256((reserve0) * (reserve1));
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Swaps an exact amount of one token for as much as possible of the other token.
    /// @dev Emits a Swap event.
    /// @dev Reverts if the output amount is less than the minimum specified or if the input token is invalid.
    /// @dev The user must approve this contract as spender on the Token he wants to swap.
    /// @param amountIn The exact amount of the input token to swap.
    /// @param amountOutMin The minimum amount of the output token expected (slippage protection).
    /// @param tokenIn The address of the token being swapped in.
    /// @param to The address to receive the output tokens.
    function swap(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address to
    ) external nonReentrant {
        if (amountOutMin == 0) revert InsufficientOutputAmount();
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        if (tokenIn != token0 && tokenIn != token1) revert Forbidden();
        if (tokenIn == token0) {
            if (amountOutMin > _reserve1) revert InsufficientLiquidity();
        } else {
            if (amountOutMin > _reserve0) revert InsufficientLiquidity();
        }
        if (amountIn == 0) revert InsufficientInputAmount();
        address _token0 = token0;
        address _token1 = token1;

        uint256 amount0In;
        uint256 amount1In;
        uint256 amount0Out;
        uint256 amount1Out;

        if (tokenIn == _token0) {
            IERC20(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                amountIn
            );
            amount0In = IERC20(tokenIn).balanceOf(address(this)) - _reserve0;
            amount1In = 0;
            amount1Out = getAmountOut(amount0In, _reserve0, _reserve1);
            if (amount1Out < amountOutMin) revert InsufficientOutputAmount();
            amount0Out = 0;
        } else {
            IERC20(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                amountIn
            );
            amount0In = 0;
            amount1In = IERC20(tokenIn).balanceOf(address(this)) - _reserve0;
            amount0Out = getAmountOut(amount1In, _reserve1, _reserve0);
            if (amount0Out < amountOutMin) revert InsufficientOutputAmount();
            amount1Out = 0;
        }

        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);

        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));

        {
            // Adjusted balances to account for fees
            uint256 balance0Adjusted = (balance0 * FEE_DENOMINATOR) -
                (amount0In * FEE_PERCENT);
            uint256 balance1Adjusted = (balance1 * FEE_DENOMINATOR) -
                (amount1In * FEE_PERCENT);
            // Check K invariant
            if (
                balance0Adjusted * balance1Adjusted <
                uint256(_reserve0) * uint256(_reserve1) * (FEE_DENOMINATOR**2)
            ) revert KInvariant();
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @notice Returns the maximum amount of `token` that can be lent via flash loan.
    /// @param token The address of the token to be lent.
    /// @return The maximum amount available to be lent.
    function maxFlashLoan(address token)
        external
        view
        override
        returns (uint256)
    {
        if (token == token0) {
            return reserve0;
        } else if (token == token1) {
            return reserve1;
        } else {
            return 0;
        }
    }

    /// @notice Calculates the fee for borrowing the given amount of `token` via flash loan.
    /// @param token The address of the token to be lent.
    /// @param amount The amount of `token` to borrow.
    /// @return The fee amount in `token` to be charged for the loan.
    function flashFee(address token, uint256 amount)
        external
        view
        override
        returns (uint256)
    {
        if (token != token0 && token != token1) revert Forbidden();
        return (amount * FEE_PERCENT) / FEE_DENOMINATOR;
    }

    /// @notice Initiates a flash loan of `amount` tokens to the `receiver`.
    /// @dev Reverts if the token is invalid or if the amount is zero.
    /// @dev The `receiver` must implement the IERC3156FlashBorrower interface.
    /// @param receiver The contract that will receive the tokens and execute the callback.
    /// @param token The address of the token to be lent.
    /// @param amount The amount of tokens to lend.
    /// @param data Arbitrary data structure, intended to contain user-defined parameters.
    /// @return True if the flash loan was successful.
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant returns (bool) {
        if (token != token0 && token != token1) revert Forbidden();
        if (amount == 0) revert InsufficientInputAmount();

        uint256 fee = this.flashFee(token, amount);
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        _safeTransfer(token, address(receiver), amount);

        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) ==
                keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "Callback failed"
        );

        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(balanceAfter >= balanceBefore + fee, "Repayment failed");

        return true;
    }

    /// @notice Transfers any excess balance tokens to the specified address.
    /// @dev Can be used to recover tokens sent to the contract by mistake.
    /// @dev Emits a Skim event.
    /// @param to The address to receive the excess tokens.
    function skim(address to) external nonReentrant {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(
            _token0,
            to,
            IERC20(_token0).balanceOf(address(this)) - (reserve0)
        );
        _safeTransfer(
            _token1,
            to,
            IERC20(_token1).balanceOf(address(this)) - (reserve1)
        );
        emit Skim(to);
    }

    /// @notice Updates the reserves to match the current balances.
    /// @dev Emits a Sync event.
    function sync() external nonReentrant {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
        emit Sync(reserve0, reserve1);
    }

    /// @notice Returns the name of the token.
    /// @return The name of the token.
    function name() public pure override returns (string memory) {
        return "Uniswap V2";
    }

    /// @notice Returns the symbol of the token.
    /// @return The symbol of the token.
    function symbol() public pure override returns (string memory) {
        return "UNI-V2";
    }

    /// @notice Returns the number of decimals used by the token.
    /// @return The number of decimals.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Returns the current reserves of token0 and token1, and the last block timestamp.
    /// @return _reserve0 The reserve of token0.
    /// @return _reserve1 The reserve of token1.
    /// @return _blockTimestampLast The last block timestamp when reserves were updated.
    function getReserves()
        public
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function getAmountOut(
        uint256 amountIn,
        uint112 reserveIn,
        uint112 reserveOut
    ) internal pure returns (uint256 amountOut) {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 && reserveOut == 0) revert InsufficientLiquidity();

        uint256 feeDenominator = FEE_DENOMINATOR;
        uint256 feeNumerator = feeDenominator - FEE_PERCENT;
        uint256 amountInWithFee = amountIn * feeNumerator;
        uint256 numerator = amountInWithFee * (reserveOut);
        uint256 denominator = reserveIn * feeDenominator + amountInWithFee;

        amountOut = numerator / denominator;
    }

    function _mintFee(uint112 _reserve0, uint112 _reserve1)
        private
        returns (bool feeOn)
    {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = FixedPointMathLib.sqrt(
                    uint256(_reserve0) * (_reserve1)
                );
                uint256 rootKLast = FixedPointMathLib.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply() * (rootK - (rootKLast));
                    uint256 denominator = (rootK * 5) + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    function _addLiquidity(
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        (uint112 reserveA, uint112 reserveB, ) = getReserves();
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin)
                    revert InsufficientInputAmount();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                if (amountAOptimal < amountAMin)
                    revert InsufficientInputAmount();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }


    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        if (amountA <= 0) revert InsufficientInputAmount();
        amountB = (amountA * reserveB) / reserveA;
    }

    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        require(
            balance0 <= type(uint112).max && balance1 <= type(uint112).max,
            "Overflow"
        );
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        unchecked {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (timeElapsed > 0 && reserve0 > 0 && reserve1 > 0) {
                // Accumulate price
                price0CumulativeLast +=
                    uint256(
                        FixedPointMathLib.mulDiv(_reserve1, 2**112, _reserve0)
                    ) *
                    timeElapsed;
                price1CumulativeLast +=
                    uint256(
                        FixedPointMathLib.mulDiv(_reserve0, 2**112, _reserve1)
                    ) *
                    timeElapsed;
            }
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success, "Transfer failed");

        if (data.length > 0) {
            // Return data is optional
            require(data.length == 32, "Invalid return data");
            bool result;
            assembly {
                result := mload(add(data, 32))
            }
            require(result, "ERC20 operation did not succeed");
        }
    }

}
