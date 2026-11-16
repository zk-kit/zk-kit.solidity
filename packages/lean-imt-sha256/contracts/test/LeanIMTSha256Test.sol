// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {LeanIMTSha256, LeanIMTSha256Data} from "../LeanIMTSha256.sol";

contract LeanIMTSha256Test {
    LeanIMTSha256Data public data;

    function insert(uint256 leaf) external {
        LeanIMTSha256.insert(data, leaf);
    }

    function insertMany(uint256[] calldata leaves) external {
        LeanIMTSha256.insertMany(data, leaves);
    }

    function update(uint256 oldLeaf, uint256 newLeaf, uint256[] calldata siblingNodes) external {
        LeanIMTSha256.update(data, oldLeaf, newLeaf, siblingNodes);
    }

    function remove(uint256 leaf, uint256[] calldata siblingNodes) external {
        LeanIMTSha256.remove(data, leaf, siblingNodes);
    }

    function has(uint256 leaf) external view returns (bool) {
        return LeanIMTSha256.has(data, leaf);
    }

    function indexOf(uint256 leaf) external view returns (uint256) {
        return LeanIMTSha256.indexOf(data, leaf);
    }

    function root() public view returns (uint256) {
        return LeanIMTSha256.root(data);
    }
}
