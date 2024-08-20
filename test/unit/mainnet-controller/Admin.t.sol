// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "test/unit/UnitTestBase.t.sol";

contract MainnetAdminTests is UnitTestBase {

    bytes32 mintRecipient1 = bytes32(uint256(uint160(makeAddr("mintRecipient1"))));
    bytes32 mintRecipient2 = bytes32(uint256(uint160(makeAddr("mintRecipient2"))));

    function test_setMintRecipient_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setMintRecipient(1, mintRecipient1);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setMintRecipient(1, mintRecipient1);
    }

    function test_setMintRecipient() public {
        assertEq(mainnetController.mintRecipients(1), bytes32(0));
        assertEq(mainnetController.mintRecipients(2), bytes32(0));

        vm.prank(admin);
        mainnetController.setMintRecipient(1, mintRecipient1);

        assertEq(mainnetController.mintRecipients(1), mintRecipient1);

        vm.prank(admin);
        mainnetController.setMintRecipient(2, mintRecipient2);

        assertEq(mainnetController.mintRecipients(2), mintRecipient2);

        vm.prank(admin);
        mainnetController.setMintRecipient(1, mintRecipient2);

        assertEq(mainnetController.mintRecipients(1), mintRecipient2);
    }

}