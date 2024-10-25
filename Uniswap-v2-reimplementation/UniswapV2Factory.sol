// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "./UniswapV2Pair.sol";

contract UniswapV2Factory {
    address public feeTo;
    address public feeToSetter;

    event PairCreated(address indexed token0, address indexed token1, address pair);

    error identicalAddresses();
    error zeroAddress();
    error existingPair();
    error create2Failed();
    error forbidden();
    
    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    /// @notice Creates a UniswapV2Pair with the given tokens passed as arguments.
    /// @dev Emits a PairCreated event.
    /// @dev Reverts if one of the tokens provided is zero address or if pair is already existing
    /// @param tokenA The first token of the Pair.
    /// @param tokenB The second token of the Pair.
    /// @return pair The address of the deployed Pair.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert identicalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert zeroAddress();

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes memory bytecode = getCreationBytecode(token0, token1);

        pair = computeAddress(salt, keccak256(bytecode));
        if (pair.code.length != 0) revert existingPair();

        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        if(pair == address(0)) revert create2Failed();

        emit PairCreated(token0, token1, pair);
    }

    /// @notice Returns the address of an existing Pair.
    /// @param tokenA The first token of the Pair.
    /// @param tokenB The second token of the Pair.
    /// @return pair The address of the wanted Pair.
    function getPairAddress(address tokenA, address tokenB) external view returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 bytecodeHash = keccak256(getCreationBytecode(token0, token1));
        pair = computeAddress(salt, bytecodeHash);
    }

    function setFeeTo(address _feeTo) external {
        if (msg.sender != feeToSetter) revert forbidden();
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        if (msg.sender != feeToSetter) revert forbidden();
        feeToSetter = _feeToSetter;
    }

    function computeAddress(bytes32 salt, bytes32 bytecodeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            bytecodeHash
        )))));
    }

    function getCreationBytecode(address token0, address token1) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(UniswapV2Pair).creationCode,
            abi.encode(token0, token1)
        );
    }
}
