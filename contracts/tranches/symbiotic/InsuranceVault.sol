// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IStrataCDO } from "../interfaces/IStrataCDO.sol";
import { CDOComponent }  from "../base/CDOComponent.sol";
import { IInsuranceVault } from "./interfaces/IInsuranceVault.sol";

/// @title InsuranceVault
/// @notice Holds the coverage assets backing a market's outstanding `insuranceAmount` and pays a
///         redeeming Senior its covered slice.
/// @dev One vault per CDO. Slashed Symbiotic collateral (uniBTC) is swapped off-chain into a liquid
///      coverage token (e.g. USDC) and funded here, deliberately never entering the strategy: on a
///      loss the underlying is usually the impaired asset, so buying back into it would expose
///      Senior to a further drop. The claim therefore settles by paying out at redemption rather
///      than by injecting into the strategy, and the vault balance never counts toward `nav`.
contract InsuranceVault is IInsuranceVault, CDOComponent {

    /// @notice The token used for funded coverage (e.g. USDC).
    address public coverageToken;

    /// @notice Funded coverage available to pay redeeming Seniors, in coverage-token units.
    /// @dev Tracked through {recordFunding} and {payCoverage} rather than read from the token balance, so a
    ///      stray transfer cannot pass itself off as funded coverage. Any balance above this is unbacked
    ///      dust and can be swept with {rescue}.
    uint256 public fundedCoverage;

    error InsufficientCoverage(uint256 requested, uint256 available);
    error CoverageTokenInUse(uint256 fundedCoverage);

    event Funded(address indexed from, uint256 amount, uint256 fundedCoverage);
    event CoveragePaid(address indexed receiver, uint256 amount, uint256 fundedCoverage);
    event CoverageTokenSet(address indexed token);
    event Rescued(address indexed token, address indexed receiver, uint256 amount);

    function initialize(
        address owner_,
        address acm_,
        IStrataCDO cdo_,
        address coverageToken_
    ) external reinitializer(1) {
        if (address(cdo_) == address(0) || coverageToken_ == address(0)) {
            revert ZeroAddress();
        }
        AccessControlled_init(owner_, acm_);
        cdo = cdo_;
        coverageToken = coverageToken_;
    }

    /// @notice Decimals of the coverage token, so the CDO can scale a base-asset amount into it.
    function coverageTokenDecimals() external view returns (uint8) {
        return IERC20Metadata(address(coverageToken)).decimals();
    }

    /// @notice Records funded coverage from the CDO, setting the coverage token if empty.
    /// @dev Driven by `StrataCDO.fundInsuranceClaim`, which is reserve-manager gated and transfers the swapped
    ///      proceeds here before calling this. The token is chosen per finalization (the keeper may
    ///      swap the slashed uniBTC into whichever stablecoin is liquid at the time), but it can only
    ///      change while no funded coverage is held, so a payout never draws on a mixed balance.
    /// @param token The coverage token the proceeds were transferred in.
    /// @param amount The amount transferred, in `token` units.
    function recordFunding(address token, uint256 amount) external onlyCDO {
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (token == address(0)) {
            revert ZeroAddress();
        }
        if (token != address(coverageToken)) {
            if (fundedCoverage > 0) {
                revert CoverageTokenInUse(fundedCoverage);
            }
            coverageToken = token;
            emit CoverageTokenSet(token);
        }
        fundedCoverage += amount;
        emit Funded(msg.sender, amount, fundedCoverage);
    }

    /// @notice Pays a redeeming Senior its covered slice.
    /// @dev Reverts when the claim is not yet funded, rather than short-paying the user. The keeper
    ///      must finalize the Symbiotic claim and fund the vault before Senior redemptions clear.
    function payCoverage(uint256 amount, address receiver) external onlyCDO {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }
        if (amount > fundedCoverage) {
            revert InsufficientCoverage(amount, fundedCoverage);
        }
        fundedCoverage -= amount;
        SafeERC20.safeTransfer(IERC20(coverageToken), receiver, amount);
        emit CoveragePaid(receiver, amount, fundedCoverage);
    }

    /// @notice Changes the coverage token.
    /// @dev Only while no funded coverage is held, so a payout can never draw on a token the accounting did
    ///      not size.
    function setCoverageToken(address token) external onlyOwner {
        if (token == address(0)) {
            revert ZeroAddress();
        }
        if (fundedCoverage > 0) {
            revert CoverageTokenInUse(fundedCoverage);
        }
        coverageToken = token;
        emit CoverageTokenSet(token);
    }

    /// @notice Recovers tokens sent here by mistake.
    /// @dev For the coverage token only the balance above the tracked `fundedCoverage` can be swept, so
    ///      live claims stay backed.
    function rescue(address token, address receiver, uint256 amount) external onlyOwner {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }
        if (token == address(coverageToken)) {
            uint256 unbacked = IERC20(coverageToken).balanceOf(address(this)) - fundedCoverage;
            if (amount > unbacked) {
                revert CoverageTokenInUse(fundedCoverage);
            }
        }
        SafeERC20.safeTransfer(IERC20(token), receiver, amount);
        emit Rescued(token, receiver, amount);
    }
}
