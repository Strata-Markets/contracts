// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccountingStorage} from "../../contracts/tranches/accounting/AccountingStorage.sol";

/// @dev Read the public tuple getter as a struct for field assertions.
library BoughtProjectionTestLib {
    struct Projection {
        int256 net;
        uint256 losses;
    }

    function read(address accounting) internal view returns (Projection memory bought) {
        (bought.net, bought.losses) = AccountingStorage(accounting).srtBoughtProjection();
    }
}
