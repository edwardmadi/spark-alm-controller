// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

contract MockPsm {

    address public gem;

    constructor(address _gem) {
        gem = _gem;
    }

}
