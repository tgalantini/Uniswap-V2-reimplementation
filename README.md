# Uniswap-V2-reimplementation
A modern twist on Uniswap v2, More gas efficient, Simple, featuring new standards and user-friendly UniswapV2Pair not requiring a router.

-Based on solidity 0.8.27

-Removed Safemath
-Unchecked blocks to overflow and save gas
-Solady ERC20 to accomplish the LP token
-Modern reentrancy protection
-Built in flash loan functions compliant with ERC-3156
-Built in safety checks for swap, mint, burn functions
-Custom revert errors to save on gas
-Gas efficient way of returning pairs to users in Factory
-Constructor in Pair contract to avoid initialize function
-No hardcoded fees, no magic numbers
-Immutable variables to save gas
-Beautiful code with natspec
-_safeTransfer memory expansion attack protection

Happy Usage

https://x.com/tga_eth
