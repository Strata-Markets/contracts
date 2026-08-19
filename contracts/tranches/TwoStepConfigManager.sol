// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessControlled } from "../governance/AccessControlled.sol";
import { IStrataCDO, IStrataCDOSetters } from "./interfaces/IStrataCDO.sol";
import { ISharesCooldown } from "./interfaces/cooldown/ISharesCooldown.sol";

interface IStrataCDOFull is IStrataCDO, IStrataCDOSetters  {
    function acm () external view returns (address);
    function owner () external view returns (address);
}

/// @notice Shared types and events for pending exit fee configuration.
abstract contract PendingFeesTypes {
    /// @notice Pending exit fee change that becomes executable after a delay.
    struct TPendingExitFeeChange {
        uint256 feeJrt;
        uint256 feeSrt;
        uint64 executeAfter;
    }
    /// @notice Emitted when a new exit fee change is scheduled.
    event ExitFeeChangeScheduled(
        uint256 feeJrt,
        uint256 feeSrt,
        uint64 executeAfter
    );
    /// @notice Emitted when a pending exit-fee change is executed on the CDO.
    event ExitFeeChangeExecuted(
        uint256 feeJrt,
        uint256 feeSrt
    );
    /// @notice Emitted when a pending exit fee change is cancelled.
    event ExitFeeChangeCancelled();
}

/// @notice Shared types and events for pending exit mode configuration.
abstract contract PendingExitModeTypes {
    /// @notice Pending exit mode change that becomes executable after a delay.
    struct TPendingExitModeBoundsChange {
        ISharesCooldown.TExitUpperBounds bounds;
        uint64 executeAfter;
    }
    /// @notice Emitted when a new exit fee change is scheduled.
    event ExitModeBoundsChangeScheduled(
        ISharesCooldown.TExitUpperBounds boundsJrt,
        ISharesCooldown.TExitUpperBounds boundsSrt,
        uint64 executeAfter
    );
    /// @notice Emitted when a pending exit-fee change is executed on the CDO.
    event ExitModeBoundsChangeExecuted(
        ISharesCooldown.TExitUpperBounds boundsJrt,
        ISharesCooldown.TExitUpperBounds boundsSrt
    );
    /// @notice Emitted when a pending exit fee change is cancelled.
    event ExitModeBoundsChangeCancelled();

    function validateBounds (ISharesCooldown.TExitUpperBounds calldata bounds) internal pure {
        require(bounds.p0 <= bounds.p1, 'P1>P2');

        require(bounds.r0.feePpm <= 0.05e6, "InvalidFee");
        require(bounds.r1.feePpm <= 0.05e6, "InvalidFee");
        require(bounds.r2.feePpm <= 0.05e6, "InvalidFee");

        require(bounds.r0.sharesLock <= 30 days, "InvalidCooldown");
        require(bounds.r1.sharesLock <= 30 days, "InvalidCooldown");
        require(bounds.r2.sharesLock <= 30 days, "InvalidCooldown");
    }
}


/**
 * @title TwoStepConfigManager
 * @notice
 *  Two-step / time-delayed manager for configuration values on Strata Protocol.
 *
 *  In the current version it only manages exit fees:
 *   - Step 1: schedule a pending exit fee change with a delay
 *   - Step 2: after the delay, execute the change on the underlying CDO
 *
 *  This contract is intended to be extended later with additional
 *  two-step configuration methods (e.g. other risk params).
 */
contract TwoStepConfigManager is AccessControlled, PendingFeesTypes, PendingExitModeTypes{

    uint256 public constant MIN_DELAY = 1 days;
    uint256 public constant MAX_DELAY = 30 days;
    IStrataCDOFull public immutable cdo;

    TPendingExitFeeChange public pendingExitFeeChange;
    TPendingExitModeBoundsChange public pendingExitModeBoundsJrt;
    TPendingExitModeBoundsChange public pendingExitModeBoundsSrt;

    constructor (IStrataCDOFull _cdo) {
        cdo = _cdo;
    }

    function initialize() public virtual initializer {
        AccessControlled_init(cdo.owner(), cdo.acm());
    }

    /**
     * ============================================
     *              Exit fee configuration
     * ============================================
     */

    /**
     * @notice Step 1: Schedule a new exit-fee configuration.
     * @param feeJrt  New exit fee for JRT (junior tranche).
     * @param feeSrt  New exit fee for SRT (senior tranche).
     * @param delay   Delay in seconds until the change can be executed.
     *                Must be greater or equal than MIN_DELAY.
     */
    function scheduleExitFeeChange(
        uint256 feeJrt,
        uint256 feeSrt,
        uint256 delay
    ) external onlyRole(PROPOSER_CONFIG_ROLE) {

        uint256 feeJrtCurrent = cdo.exitFeeJrt();
        uint256 feeSrtCurrent = cdo.exitFeeSrt();
        if (feeJrt <= feeJrtCurrent && feeSrt <= feeSrtCurrent) {
            // Lower the fee in one go
            emit ExitFeeChangeScheduled(feeJrt, feeSrt, 0);
            cdo.setExitFees(feeJrt, feeSrt);
            emit ExitFeeChangeExecuted(feeJrt, feeSrt);
            return;
        }

        require(MIN_DELAY <= delay && delay <= MAX_DELAY, "InvalidDelay");

        uint64 executeAfter = uint64(block.timestamp + delay);
        pendingExitFeeChange = TPendingExitFeeChange({
            feeJrt: feeJrt,
            feeSrt: feeSrt,
            executeAfter: executeAfter
        });
        emit ExitFeeChangeScheduled(feeJrt, feeSrt, executeAfter);
    }

    /**
     * @notice Step 2: execute the pending exit fee change on the underlying CDO.
     */
    function executeExitFeeChange() external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        TPendingExitFeeChange memory pending = pendingExitFeeChange;
        require(pending.executeAfter != 0, "NoPendingChange");
        require(block.timestamp >= pending.executeAfter, "TooEarly");
        // Clear pending state
        delete pendingExitFeeChange;
        // External call to the underlying contract.
        cdo.setExitFees(pending.feeJrt, pending.feeSrt);
        emit ExitFeeChangeExecuted(pending.feeJrt, pending.feeSrt);
    }

    /**
     * @notice Cancel the currently pending exit fee change, if any.
     */
    function cancelExitFeeChange() external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        require(pendingExitFeeChange.executeAfter != 0, "NoPendingChange");
        delete pendingExitFeeChange;
        emit ExitFeeChangeCancelled();
    }

    /**
     * ============================================
     *         Exit mode upper bounds configuration
     * ============================================
     */

    /**
     * @notice Step 1: Schedule a new exit mode bounds configuration.
     * @param boundsJrt Exit mode upper bounds for the junior tranche (JRT), defining coverage ratio thresholds and corresponding fee/lock parameters.
     * @param boundsSrt Exit mode upper bounds for the senior tranche (SRT), defining coverage ratio thresholds and corresponding fee/lock parameters.
     * @param delay Delay in seconds until the change can be executed.
     *              Must be greater or equal than MIN_DELAY.
     */
    function scheduleExitModeBoundsChange(
        ISharesCooldown.TExitUpperBounds calldata boundsJrt,
        ISharesCooldown.TExitUpperBounds calldata boundsSrt,
        uint256 delay
    ) external onlyRole(PROPOSER_CONFIG_ROLE) {

        validateBounds(boundsJrt);
        validateBounds(boundsSrt);
        require(delay >= MIN_DELAY && delay <= MAX_DELAY, "InvalidDelay");

        uint64 executeAfter = uint64(block.timestamp + delay);
        pendingExitModeBoundsJrt = TPendingExitModeBoundsChange({
            bounds: boundsJrt,
            executeAfter: executeAfter
        });
        pendingExitModeBoundsSrt = TPendingExitModeBoundsChange({
            bounds: boundsSrt,
            executeAfter: executeAfter
        });
        emit ExitModeBoundsChangeScheduled(boundsJrt, boundsSrt, executeAfter);
    }

    /**
     * @notice Step 2: execute the pending exit mode bounds change on the underlying CDO.
     */
    function executeExitModeBoundsChange() external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        TPendingExitModeBoundsChange memory pendingJrt = pendingExitModeBoundsJrt;
        TPendingExitModeBoundsChange memory pendingSrt = pendingExitModeBoundsSrt;
        require(pendingJrt.executeAfter != 0, "NoPendingChange");
        require(block.timestamp >= pendingJrt.executeAfter, "TooEarly");
        // Clear pending state
        delete pendingExitModeBoundsJrt;
        delete pendingExitModeBoundsSrt;
        // External call to the underlying contract.

        cdo.sharesCooldown().setVaultExitBounds(address(cdo.jrtVault()), pendingJrt.bounds);
        cdo.sharesCooldown().setVaultExitBounds(address(cdo.srtVault()), pendingSrt.bounds);

        emit ExitModeBoundsChangeExecuted(pendingJrt.bounds, pendingSrt.bounds);
    }

    /**
     * @notice Cancel the currently pending exit mode bounds change, if any.
     */
    function cancelExitModeBoundsChange() external onlyRole(UPDATER_STRAT_CONFIG_ROLE) {
        require(pendingExitModeBoundsJrt.executeAfter != 0, "NoPendingChange");
        delete pendingExitModeBoundsJrt;
        delete pendingExitModeBoundsSrt;
        emit ExitModeBoundsChangeCancelled();
    }
}
