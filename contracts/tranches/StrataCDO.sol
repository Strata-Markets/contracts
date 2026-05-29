// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 ____  _             _          ____ ____   ___
/ ___|| |_ _ __ __ _| |_ __ _  / ___|  _ \ / _ \
\___ \| __| '__/ _` | __/ _` || |   | | | | | | |
 ___) | |_| | | (_| | || (_| || |___| |_| | |_| |
|____/ \__|_|  \__,_|\__\__,_| \____|____/ \___/
*/

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AccessControlled } from "../governance/AccessControlled.sol";
import { IErrors } from "./interfaces/IErrors.sol";
import { ITranche } from "./interfaces/ITranche.sol";
import { IStrategy } from "./interfaces/IStrategy.sol";
import { IStrataCDO, IStrataCDOSetters } from "./interfaces/IStrataCDO.sol";
import { TActionState } from "./structs/TActionState.sol";
import { IAccounting } from "./interfaces/IAccounting.sol";
import { ISharesCooldown } from "./interfaces/cooldown/ISharesCooldown.sol";
import { RoundingGuard } from "./utils/RoundingGuard.sol";


/// @notice Core CDO contract that orchestrates Tranches, Accounting, and Strategy
/// @dev Manages deposits, withdrawals, and asset distribution between tranches
contract StrataCDO is IErrors, IStrataCDO, IStrataCDOSetters, AccessControlled {

    /// @dev Accounting contract for managing asset flows and TVL redistribution
    /// @notice This contract handles the calculation of asset distribution between tranches based on target APRs
    /// @dev It's responsible for updating tranche balances, calculating risk-adjusted returns, and maintaining the reserve
    IAccounting public accounting;

    /// @dev The underlying investment strategy contract for this CDO
    /// @notice This contract implements the specific investment logic, e.g., USDe staking
    /// @dev Responsible for handling deposits, withdrawals, and calculating total assets
    /// @dev Interacts directly with external protocol to generate returns
    IStrategy public strategy;

    /// @notice Junior (BB) Tranche
    ITranche public jrtVault;

    /// @notice Senior (AA) Tranche
    ITranche public srtVault;

    /// @dev Address of the treasury wallet
    /// @dev Used as the recipient when reducing reserves
    /// @dev Can be updated by the RESERVE_MANAGER_ROLE
    address public treasury;

    /// @dev Controls the ability to deposit into or withdraw from the junior tranche
    TActionState public actionsJrt;

    /// @dev Controls the ability to deposit into or withdraw from the senior tranche
    TActionState public actionsSrt;

    /// @dev Configurable minimum JRT price per share, below which the protocol automatically pauses deposits
    uint256 public jrtShortfallPausePrice;

    /// @dev Withdrawal fees for the Junior Tranche
    uint256 public exitFeeJrt;

    /// @dev Withdrawal fees for the Senior Tranche
    uint256 public exitFeeSrt;

    ISharesCooldown public sharesCooldown;

    uint256 public immutable baseAssetDecimals;

    event DepositsStateChanged(address indexed tranche, bool enabled);
    event WithdrawalsStateChanged(address indexed tranche, bool enabled);
    event ReserveReduced(address token, uint256 amount);
    event ReserveDistributed(uint256 jrtAmount, uint256 srtAmount);
    event TreasurySet(address treasury);
    event ShortfallPaused();
    event JrtShortfallPausePriceSet(uint256 pricePerShare);
    event ExitFeesSet(uint256 jrt, uint256 srt);
    event SharesCooldownSet(address sharesCooldown);


    /// @notice Restricts function access to only the junior (JRT) or senior (SRT) tranche contracts
    modifier onlyTranche() {
        if (msg.sender != address(jrtVault) && msg.sender != address(srtVault)) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    constructor (IERC20Metadata baseAsset) {
        baseAssetDecimals = baseAsset.decimals();
    }

    function initialize(
        address owner_,
        address acm_
    ) public virtual initializer {
        AccessControlled_init(owner_, acm_);
        jrtShortfallPausePrice = 0.01e18;
    }

    /// @notice Calculates the total assets for a specific tranche
    /// @dev Retrieves the overall TVL from the strategy and determines the asset split
    /// @param tranche The address of the tranche (junior or senior) to return assets for
    /// @return The total assets allocated to the specified tranche
    /// @dev This function:
    ///      1. Gets the total TVL from the strategy
    ///      2. Uses the accounting contract to calculate the asset split
    ///      3. Returns the assets allocated to the specified tranche
    function totalAssets(address tranche) public view returns (uint256) {
        (uint256 jrtAssets, uint256 srtAssets, ) = accounting.totalAssets();
        if (isJrt(tranche)) {
            return jrtAssets;
        }
        return srtAssets;
    }

    /// @notice Returns the current total assets held in the strategy
    /// @dev This method retrieves the fresh amount of assets directly from the strategy contract
    /// @return uint256 The current total assets in the strategy
    function totalStrategyAssets() public view returns (uint256) {
        return strategy.totalAssets();
    }

    function totalStrategyAssets(uint256 latestNav, uint256 timestamp) public view returns (uint256) {
        return strategy.totalAssets(latestNav, timestamp);
    }

    function pricePerShare(address tranche) public view returns (uint256) {
        uint256 assets = totalAssets(tranche);
        uint256 supply = ITranche(tranche).totalSupply();
        return calculatePricePerShare(assets, supply, baseAssetDecimals);
    }

    function maxDeposit(address tranche) external view returns (uint256) {
        bool isJrt_ = isJrt(tranche);
        bool isDepositEnabled = isJrt_ ? actionsJrt.isDepositEnabled : actionsSrt.isDepositEnabled;
        if (isDepositEnabled == false) {
            return 0;
        }
        return accounting.maxDeposit(isJrt_);
    }
    function maxWithdraw(address tranche) external view returns (uint256) {
        return maxWithdraw(tranche, address(0));
    }

    function maxWithdraw(address tranche, address owner) public view returns (uint256) {
        bool isJrt_ = isJrt(tranche);
        bool isWithdrawEnabled = isJrt_ ? actionsJrt.isWithdrawEnabled : actionsSrt.isWithdrawEnabled;
        if (isWithdrawEnabled == false) {
            return 0;
        }
        bool ownerIsSharesCooldown = owner != address(0) && owner == address(sharesCooldown);
        return accounting.maxWithdraw(isJrt_, ownerIsSharesCooldown);
    }

    /// @notice Determines the exit mode and associated parameters for a withdrawal from a specific tranche.
    /// @dev Checks if shares cooldown is configured and calculates exit parameters based on coverage ratio.
    ///      If the owner is the shares cooldown contract, returns ERC4626 mode with no fees.
    ///      Otherwise, returns either SharesLock mode (if cooldown required) or Fee mode with applicable fees.
    /// @param tranche The address of the tranche (junior or senior).
    /// @param owner The shares owner. No fee or cooldown is applied when the shares cooldown contract redeems.
    /// @return mode The exit mode (ERC4626, SharesLock, or Fee).
    /// @return fee The exit fee in 18 decimals (0 if no fee applies).
    /// @return cooldownSeconds The cooldown period in seconds (0 if no cooldown applies).
    function calculateExitMode (address tranche, address owner) external view returns (TExitMode mode, uint256 fee, uint32 cooldownSeconds) {
        if (address(sharesCooldown) != address(0)) {
            if (owner == address(sharesCooldown)) {
                return (TExitMode.ERC4626, 0, 0);
            }
            uint32 cov = coverage();
            ISharesCooldown.TExitParams memory exit = sharesCooldown.calculateExitParams(tranche, cov);
            if (exit.feePpm > 0) {
                // Convert to 18 decimals
                fee = uint256(exit.feePpm) * 1e18 / 1e6;
            }
            if (exit.sharesLock > 0) {
                return (TExitMode.SharesLock, fee, exit.sharesLock);
            }
        }
        if (fee == 0) {
            // default
            bool isJrt_ = isJrt(tranche);
            fee = isJrt_ ? exitFeeJrt : exitFeeSrt;
        }
        return (TExitMode.Fee, fee, 0);
    }

    /// @notice On behalf of a tranche, moves accrued fees from the tranche's TVL to the reserve.
    /// @param tranche The address of the tranche (JRT or SRT).
    /// @param assets The amount of fees to accrue.
    function accrueFee (address tranche, uint256 assets) external onlyTranche {
        accounting.accrueFee(isJrt(tranche), assets);
    }

    /// @notice Returns tranche NAVs excluding assets locked in the shares cooldown (silo).
    /// @dev Reads accounting totals and subtracts locked assets to compute available TVLs and coverage.
    function totalAssetsUnlocked() public view returns (uint256 jrtNav, uint256 srtNav) {
        // Saved Junior and Senior TVLs (not projected).
        (jrtNav, srtNav, ) = accounting.totalAssetsT0();

        // Potentially projected Junior and Senior assets.
        uint256 jrtNavLocked = jrtVault.convertToAssets(jrtVault.balanceOf(address(sharesCooldown)));
        uint256 srtNavLocked = srtVault.convertToAssets(srtVault.balanceOf(address(sharesCooldown)));

        jrtNav = jrtNav > jrtNavLocked ? jrtNav - jrtNavLocked : 0;
        srtNav = srtNav > srtNavLocked ? srtNav - srtNavLocked : 0;
        return (jrtNav, srtNav);
    }

    /// @notice Returns the coverage ratio using available TVLs (assets not locked in the silo).
    /// @dev Uses totals from totalAssetsUnlocked() so locked assets do not affect coverage.
    function coverage () public view returns (uint32) {
        (uint256 jrtNav, uint256 srtNav) = totalAssetsUnlocked();
        if (srtNav == 0) {
            return type(uint32).max;
        }
        uint256 coverage_ = jrtNav * 1e6 / srtNav;
        return coverage_ > type(uint32).max ? type(uint32).max : uint32(coverage_);
    }


    /// @notice Refreshes accounting state before tranche deposit or redemption flows.
    /// @dev Called by tranche contracts to sync balances with current strategy TVL.
    function updateAccounting () external onlyTranche {
        accounting.updateAccounting();
    }

    function deposit(address tranche, address token, uint256 tokenAmount, uint256 baseAssets) external onlyTranche nonReentrant {
        bool isJrt_ = isJrt(tranche);
        bool enabled = isJrt_ ? actionsJrt.isDepositEnabled : actionsSrt.isDepositEnabled;
        if (!enabled) {
            revert DepositsDisabled(tranche);
        }
        if (baseAssets > strategy.maxDeposit(tranche, token, tokenAmount)) {
            revert DepositRejectedByStrategy(tranche, token);
        }
        if (baseAssets > accounting.maxDeposit(isJrt_)) {
            revert DepositCapReached(tranche);
        }
        if (tokenAmount == 0 || baseAssets == 0) {
            revert ZeroAmount();
        }
        uint256 baseAssetsNet = strategy.deposit(tranche, token, tokenAmount, baseAssets, /* owner: */ tranche);

        // The strategy converts deposited assets to shares and back to assets (assets -> shares -> assets).
        // This double conversion can introduce minor rounding discrepancies even when the strategy charges no fees.
        // To prevent artificial loss from rounding errors in fee-free scenarios, we use the original deposit amount
        // if the calculated amount differs by at most 1 wei.
        baseAssetsNet = RoundingGuard.preferOriginalWithin1Wei(baseAssets, baseAssetsNet);

        uint256 jrtAssetsIn = isJrt_ ? baseAssetsNet : 0;
        uint256 srtAssetsIn = isJrt_ ? 0             : baseAssetsNet;
        accounting.updateBalanceFlow(jrtAssetsIn, 0, srtAssetsIn, 0);
        shortfallPauser();
    }

    function withdraw(address tranche, address token, uint256 tokenAmount, uint256 baseAssets, address sender, address receiver) external onlyTranche nonReentrant {
        if (tokenAmount == 0 || baseAssets == 0) {
            revert ZeroAmount();
        }
        bool isJrt_ = isJrt(tranche);
        bool enabled = isJrt_ ? actionsJrt.isWithdrawEnabled : actionsSrt.isWithdrawEnabled;
        if (!enabled) {
            revert WithdrawalsDisabled(tranche);
        }
        if (baseAssets > strategy.maxWithdraw(tranche, token, tokenAmount)) {
            revert WithdrawalRejectedByStrategy(tranche, token);
        }
        bool isSharesLockup = sender == address(sharesCooldown);
        if (baseAssets > accounting.maxWithdraw(isJrt_, isSharesLockup)) {
            revert WithdrawalCapReached(tranche);
        }
        // When the sender is the shares lockup contract, we should skip any cooldown on our side,
        // unless the underlying protocol has some cooldown/unstake process.
        bool shouldSkipCooldown = isSharesLockup == true;
        strategy.withdraw(tranche, token, tokenAmount, baseAssets, sender, receiver, shouldSkipCooldown);
        uint256 jrtAssetsOut = isJrt_ ? baseAssets : 0;
        uint256 srtAssetsOut = isJrt_ ? 0          : baseAssets;
        accounting.updateBalanceFlow(0, jrtAssetsOut, 0, srtAssetsOut);
        shortfallPauser();
    }

    /// @notice Lets a tranche refresh APRs after NAV-affecting events (e.g., fee accrual in burnSharesAsFee).
    /// @dev updates use current NAVs as a zero flow delta.
    function updateBalanceFlow() external onlyTranche {
        accounting.updateBalanceFlow(0, 0, 0, 0);
        shortfallPauser();
    }

    /// @notice Initiates a cooldown period for share redemption by transferring shares to the cooldown contract.
    /// @dev Validates withdrawal permissions and delegates to the sharesCooldown contract to handle the lock-up.
    ///      The shares are held in escrow during the cooldown period before they can be redeemed for assets.
    ///      The caller MUST transfer the required shares to the shares cooldown contract before calling this function.
    /// @param tranche The address of the tranche (junior or senior).
    /// @param token The output asset selected by the user for redemption.
    /// @param shares The amount of shares to lock for cooldown.
    /// @param sender The address initiating the cooldown (original share owner).
    /// @param receiver The address that will receive the assets after cooldown completes.
    /// @param fee The exit fee to be applied when redeeming (in 18 decimals).
    /// @param cooldownSeconds The duration of the cooldown period in seconds.
    function cooldownShares(address tranche, address token, uint256 shares, address sender, address receiver, uint256 fee, uint32 cooldownSeconds) external onlyTranche nonReentrant {
        if (shares == 0) {
            revert ZeroAmount();
        }
        bool isJrt_ = isJrt(tranche);
        bool enabled = isJrt_ ? actionsJrt.isWithdrawEnabled : actionsSrt.isWithdrawEnabled;
        if (!enabled) {
            revert WithdrawalsDisabled(tranche);
        }
        sharesCooldown.requestRedeem(ITranche(tranche), token, sender, receiver, shares, fee, cooldownSeconds);
    }

    /// @notice Determines if the given address is the Junior (BB) Tranche
    /// @dev Used to differentiate between Junior and Senior Tranches
    /// @param tranche The address to check
    /// @return bool True if the address is the Junior Tranche, false if it's the Senior Tranche
    /// @dev Reverts with InvalidTranche error if the address is neither Junior nor Senior Tranche
    function isJrt (address tranche) public view returns (bool) {
        if (tranche == address(jrtVault)) {
            return true;
        }
        if (tranche == address(srtVault)) {
            return false;
        }
        revert InvalidTranche(tranche);
    }

    /// @notice Configures the CDO with its components
    /// @dev Can only be called once by the owner after components deployment
    function configure (
        IAccounting accounting_,
        IStrategy strategy_,
        ITranche jrtVault_,
        ITranche srtVault_
    ) external onlyOwner {
        if (address(accounting) != address(0)) {
            revert AlreadyConfigured();
        }
        require(address(this) == accounting_.getCDOAddress(), "A1");
        require(address(this) ==   strategy_.getCDOAddress(), "A2");
        require(address(this) ==   jrtVault_.getCDOAddress(), "A3");
        require(address(this) ==   srtVault_.getCDOAddress(), "A4");

        accounting = accounting_;
        strategy = strategy_;
        jrtVault = jrtVault_;
        srtVault = srtVault_;

        jrtVault_.configure();
        srtVault_.configure();
    }

    /// @notice Reduces the reserve and transfers tokens to the treasury
    /// @dev Only callable by RESERVE_MANAGER_ROLE
    function reduceReserve (address token, uint256 tokenAmount) external onlyRole(RESERVE_MANAGER_ROLE) {
        if (treasury == address(0)) {
            revert ZeroAddress();
        }
        // Reverts if the token is not supported
        uint256 baseAssets = strategy.convertToAssets(token, tokenAmount, Math.Rounding.Floor);
        // Reverts if not enough reserve
        accounting.reduceReserve(baseAssets, 0, 0);
        // Transfers tokens out instantly if possible, or through the cooldown process
        strategy.reduceReserve(token, tokenAmount, treasury);
        emit ReserveReduced(token, tokenAmount);
    }

    /// @notice Reduces the reserve by distributing assets to the tranches
    /// @dev Only callable by RESERVE_MANAGER_ROLE
    function distributeReserve (uint256 jrtAmountIn, uint256 srtAmountIn) external onlyRole(RESERVE_MANAGER_ROLE) {
        // The accounting contract reverts if reserves are insufficient.
        accounting.reduceReserve(jrtAmountIn + srtAmountIn, jrtAmountIn, srtAmountIn);
        emit ReserveDistributed(jrtAmountIn, srtAmountIn);
    }

    /// @notice Sets the address of the reserve treasury
    function setReserveTreasury (address treasury_) external onlyRole(RESERVE_MANAGER_ROLE) {
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Sets action states for the tranche; zero address affects both tranches
    function setActionStates (address tranche, bool isDepositEnabled, bool isWithdrawEnabled) external onlyRole(PAUSER_ROLE) {
        if (address(tranche) == address(0)) {
            setActionStatesInner(address(jrtVault), isDepositEnabled, isWithdrawEnabled);
            setActionStatesInner(address(srtVault), isDepositEnabled, isWithdrawEnabled);
            return;
        }
        setActionStatesInner(tranche, isDepositEnabled, isWithdrawEnabled);
    }

    /// @notice Internal function to set deposit and withdrawal states for a tranche
    function setActionStatesInner (address tranche, bool isDepositEnabled, bool isWithdrawEnabled) internal {
        TActionState storage state = isJrt(tranche)? actionsJrt : actionsSrt;
        if (state.isDepositEnabled != isDepositEnabled) {
            state.isDepositEnabled = isDepositEnabled;
            emit DepositsStateChanged(tranche, isDepositEnabled);
        }
        if (state.isWithdrawEnabled != isWithdrawEnabled) {
            state.isWithdrawEnabled = isWithdrawEnabled;
            emit WithdrawalsStateChanged(tranche, isWithdrawEnabled);
        }
    }

    /// @notice Sets the exit fees for the junior and senior tranches.
    /// @dev This method is only callable by the TwoStepConfigManager. Please see {twoStepConfigManager} for more details.
    function setExitFees (uint256 feeJrt, uint256 feeSrt) external onlyTwoStepConfigManager {
        require(feeJrt <= 0.01e18, "InvalidJrtFee");
        require(feeSrt <= 0.01e18, "InvalidSrtFee");
        exitFeeJrt = feeJrt;
        exitFeeSrt = feeSrt;
        emit ExitFeesSet(feeJrt, feeSrt);
    }

    /// @notice Sets the JRT shortfall price to automatically pause the deposits, when the price falls below this price
    function setJrtShortfallPausePrice (uint256 jrtShortfallPausePrice_) external onlyRole(PAUSER_ROLE) {
        // If the shortfall pause price is above current price, deposits must be paused manually by the Pauser
        require(jrtShortfallPausePrice_ <= pricePerShare(address(jrtVault)), "ShortfallPriceTooLarge");
        jrtShortfallPausePrice = jrtShortfallPausePrice_;
        emit JrtShortfallPausePriceSet(jrtShortfallPausePrice_);
    }

    /// @notice Sets the shares cooldown contract address
    /// @param sharesCooldown_ The new shares cooldown contract address
    function setSharesCooldown (ISharesCooldown sharesCooldown_) external onlyOwner {
        sharesCooldown = sharesCooldown_;
        emit SharesCooldownSet(address(sharesCooldown_));
    }

    /// @notice Updates the valuation price and pauses activities if valuation loss is detected
    /// @dev Only callable by the valuation keeper. Automatically disables junior withdrawals and senior deposits upon entering valuation loss state
    /// @param valuationPrice The new valuation price in 18 decimals (1e18 = $1)
    function setValuationPrice (uint128 valuationPrice) external onlyValuationKeeper {
        bool valuationLossEntered = accounting.setValuationPrice(valuationPrice);
        if (valuationLossEntered) {
            actionsJrt.isWithdrawEnabled = false;
            actionsSrt.isDepositEnabled  = false;
            emit WithdrawalsStateChanged(address(jrtVault), false);
            emit DepositsStateChanged(address(srtVault), false);
        }
    }


    function shortfallPauser () internal {
        (uint256 jrtNav,,) = accounting.totalAssetsT0();
        uint256 jrtPrice = calculatePricePerShare(jrtNav, jrtVault.totalSupply(), baseAssetDecimals);
        if (jrtPrice <= jrtShortfallPausePrice) {
            actionsJrt.isDepositEnabled = false;
            actionsSrt.isDepositEnabled = false;
            emit DepositsStateChanged(address(jrtVault), false);
            emit DepositsStateChanged(address(srtVault), false);
            emit ShortfallPaused();
        }
    }

    /// @dev Returns price per share scaled to 18 decimals regardless of base asset decimals
    function calculatePricePerShare (uint256 assets, uint256 supply, uint256 assetsDecimals) internal pure returns (uint256) {
        return supply == 0
            ? 1e18
            : Math.mulDiv(assets, 10**(18 - assetsDecimals) * 1e18, supply, Math.Rounding.Floor);
    }
}
