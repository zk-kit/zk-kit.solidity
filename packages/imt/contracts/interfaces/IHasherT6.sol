// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IHasherT6 {
    function hash(uint256[5] memory) external view returns (uint256);
}
