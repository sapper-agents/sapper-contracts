// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISapperBountyPot} from "./interfaces/ISapperBountyPot.sol";

/// @notice Holds the 5% burn share until a buy-and-burn path exists. The pot credits the share to
/// this contract's earnings; `collect` pulls it in.
contract SapperBurnBuffer is Ownable2Step {
    using SafeERC20 for IERC20;

    event Collected(address indexed pot, uint256 amount);
    event Released(address indexed token, address indexed to, uint256 amount);

    constructor(address owner_) Ownable(owner_) {}

    function collect(ISapperBountyPot pot) external onlyOwner returns (uint256 amount) {
        amount = pot.earningsOf(address(this));
        pot.withdrawEarnings(amount);
        emit Collected(address(pot), amount);
    }

    function release(IERC20 token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
        emit Released(address(token), to, amount);
    }
}
