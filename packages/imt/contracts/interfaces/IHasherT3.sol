// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IHasherT3 {
    function hash(uint256[2] memory) external view returns (uint256);
}
