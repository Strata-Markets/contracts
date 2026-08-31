// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

/* solhint-disable var-name-mixedcase */

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockStrcPriceOracle
 * @dev Simple mock for the STRC price oracle used by sUSDat.
 */
contract MockStrcPriceOracle {
    uint256 public price;
    uint8 public priceDecimals;

    constructor(uint256 price_, uint8 decimals_) {
        price = price_;
        priceDecimals = decimals_;
    }

    function getPrice() external view returns (uint256, uint8) {
        return (price, priceDecimals);
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}

/**
 * @title MockWithdrawalQueueV2
 * @notice ERC721-based mock for Saturn's V2 WithdrawalQueueERC721.
 *
 * Simulates:
 * - ERC721 NFT per withdrawal request
 * - claim(tokenId) with ownerOf(tokenId) == msg.sender check
 * - processRequests(tokenIds) for operator settlement
 * - Request struct matching V2 layout
 *
 * Flow:
 * 1. Vault calls addRequest(owner, shares, minSharePrice) -> mints NFT to owner
 * 2. Test calls processAllPending() -> settles at current NAV, marks as Processed
 * 3. NFT owner calls claim(tokenId) -> transfers USDat, burns NFT
 */
contract MockWithdrawalQueueV2 is ERC721 {
    using SafeERC20 for IERC20;

    enum RequestStatus { NULL, Requested, InProgress, Processed, Claimed, Cancelled }

    struct Request {
        uint256 shares;
        uint256 usdatOwed;
        uint256 timestamp;
        uint256 minSharePrice;
        RequestStatus status;
    }

    IERC20 public immutable USDAT;
    address public immutable STAKED_USDAT;

    mapping(uint256 => Request) public requests;
    uint256 public nextTokenId;

    error NotOwner();
    error RequestNotProcessed();

    constructor(address usdat_, address stakedUsdat_)
        ERC721("sUSDat Withdrawal", "sUSDat-WQ")
    {
        USDAT = IERC20(usdat_);
        STAKED_USDAT = stakedUsdat_;
    }

    /// @notice Called by the vault to create a new withdrawal request
    /// @dev Mints an ERC721 NFT to the owner via _safeMint (triggers onERC721Received)
    function addRequest(address owner, uint256 shares, uint256 minSharePrice)
        external
        returns (uint256 tokenId)
    {
        require(msg.sender == STAKED_USDAT, "OnlyStakedUSDat");
        tokenId = nextTokenId++;
        requests[tokenId] = Request({
            shares: shares,
            usdatOwed: 0,
            timestamp: block.timestamp,
            minSharePrice: minSharePrice,
            status: RequestStatus.Requested
        });
        _safeMint(owner, tokenId);
    }

    /// @notice Claims a processed withdrawal, burns the NFT, transfers USDat
    /// @dev Requires msg.sender == ownerOf(tokenId), matching V2 behavior
    function claim(uint256 tokenId) external returns (uint256 amount) {
        require(ownerOf(tokenId) == msg.sender, "NotOwner");
        require(requests[tokenId].status == RequestStatus.Processed, "RequestNotProcessed");

        amount = requests[tokenId].usdatOwed;
        requests[tokenId].status = RequestStatus.Claimed;
        _burn(tokenId);

        USDAT.safeTransfer(msg.sender, amount);
    }

    /// @notice Simulates operator processing - settles at current NAV
    function processRequests(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            Request storage req = requests[tokenId];
            if (req.status != RequestStatus.Requested) continue;

            // Query the vault for current NAV-based conversion
            uint256 assets = ERC4626(STAKED_USDAT).convertToAssets(req.shares);
            req.usdatOwed = assets;
            req.status = RequestStatus.Processed;

            // Transfer USDat from vault to queue for later claim
            MockStakedUSDat(STAKED_USDAT).settleQueuedShares(req.shares, assets);
        }
    }

    /// @notice Test helper: process all pending withdrawal requests
    function processAllPending() external {
        for (uint256 i = 0; i < nextTokenId; i++) {
            Request storage req = requests[i];
            if (req.status == RequestStatus.Requested) {
                uint256 assets = ERC4626(STAKED_USDAT).convertToAssets(req.shares);
                req.usdatOwed = assets;
                req.status = RequestStatus.Processed;

                MockStakedUSDat(STAKED_USDAT).settleQueuedShares(req.shares, assets);
            }
        }
    }
}

/**
 * @title MockStakedUSDat
 * @notice Mock of Saturn's StakedUSDat V2 vault for testing the SaturnStrategy.
 *
 * V2 Simulates:
 * - ERC4626 vault with market-mode-dependent deposit fee (depositFeeBps)
 * - 18 decimal shares with _decimalsOffset = 12 (asset is 6 decimals)
 * - Surplus vesting (surplusVestingAmount, surplusVestingPeriod, surplusVestingStartTimestamp)
 * - Partial sweep (_surplusSwept) matching L-06 audit fix
 * - Separate WithdrawalQueueERC721 (MockWithdrawalQueueV2) for async redemptions
 * - Deposit fees stay in the vault (V2 behavior, not sent to feeRecipient)
 * - withdraw/redeem disabled (reverts with OperationNotAllowed)
 */
contract MockStakedUSDat is ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public depositFeeBps = 10; // 0.1%

    // V2: Surplus vesting state (replaces V1's STRC vesting)
    uint256 public surplusVestingAmount;
    uint256 public surplusVestingPeriod;
    uint256 public surplusVestingStartTimestamp;
    uint256 private _surplusSwept;

    // Internally tracked USDat balance (6 decimals)
    uint256 public usdatBalance;

    // V2: Separate withdrawal queue contract
    MockWithdrawalQueueV2 public queue;

    error OperationNotAllowed();

    constructor(
        IERC20 asset_,
        address /* admin_ (unused in V2 mock) */
    ) ERC4626(asset_) ERC20("Staked USDat", "sUSDat") {
        // Deploy separate mock withdrawal queue
        queue = new MockWithdrawalQueueV2(address(asset_), address(this));

        // Default surplus vesting period: 3 days (matches V2's initializeV2)
        surplusVestingPeriod = 3 days;
    }

    // ============ ERC4626 Overrides ============

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @dev previewDeposit accounts for the deposit fee
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (depositFeeBps == 0) {
            return super.previewDeposit(assets);
        }
        uint256 fee = Math.mulDiv(assets, depositFeeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        return super.previewDeposit(assets - fee);
    }

    /// @dev previewMint accounts for the deposit fee
    function previewMint(uint256 shares) public view override returns (uint256) {
        if (depositFeeBps == 0) {
            return super.previewMint(shares);
        }
        uint256 assets = super.previewMint(shares);
        return Math.mulDiv(assets, BPS_DENOMINATOR, BPS_DENOMINATOR - depositFeeBps, Math.Rounding.Ceil);
    }

    /// @dev V2: deposit fee stays in vault (usdatBalance includes fee)
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // V2: _sweep vested surplus first, then entire deposit (including fee) goes to vault
        _sweep();
        usdatBalance += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Disable standard withdraw/redeem -- must use requestRedeem/claim
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert OperationNotAllowed();
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert OperationNotAllowed();
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    /// @dev V2: previewWithdraw returns 0 (withdraw is disabled)
    function previewWithdraw(uint256) public pure override returns (uint256) {
        return 0;
    }

    /// @dev totalAssets = usdatBalance + vestedSurplus
    /// Matches V2 formula: usdatBalance + _unsweptSurplus() - getUnvestedSurplus()
    /// Note: No module values in mock (STRCMirrorModule / STRConModule = 0)
    function totalAssets() public view override returns (uint256) {
        uint256 unswept = _unsweptSurplus();
        uint256 unvested = getUnvestedSurplus();
        uint256 vestedSurplus = unswept > unvested ? unswept - unvested : 0;
        return usdatBalance + vestedSurplus;
    }

    // ============ Surplus Vesting (V2) ============

    /// @notice Returns the unvested portion of the current surplus tranche
    function getUnvestedSurplus() public view returns (uint256) {
        uint256 amount = surplusVestingAmount;
        if (amount == 0) return 0;

        uint256 period = surplusVestingPeriod;
        uint256 elapsed = block.timestamp - surplusVestingStartTimestamp;
        if (elapsed >= period) return 0;

        return Math.mulDiv(period - elapsed, amount, period, Math.Rounding.Ceil);
    }

    /// @dev Returns the portion of the active tranche not yet folded into usdatBalance
    function _unsweptSurplus() internal view returns (uint256) {
        return surplusVestingAmount - _surplusSwept;
    }

    /// @dev Partial sweep: folds vested surplus into usdatBalance
    /// Matches the L-06 audit fix implementation
    function _sweep() internal {
        uint256 amount = surplusVestingAmount;
        if (amount == 0) return;

        uint256 unvested = getUnvestedSurplus();
        uint256 vested = amount - unvested;
        uint256 releasable = vested - _surplusSwept;

        if (releasable != 0) {
            _surplusSwept = vested;
            usdatBalance += releasable;
        }

        if (unvested == 0) {
            surplusVestingAmount = 0;
            _surplusSwept = 0;
        }
    }

    /// @notice Simulate surplus distribution (like transferInSurplus in V2)
    /// @dev Transfers USDat from caller and starts a new vesting tranche
    function transferInSurplus(uint256 amount) external {
        // Sweep any remaining vested surplus first
        _sweep();

        // Pull USDat from the caller (simulates the SURPLUS_SOURCE)
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        surplusVestingAmount = amount;
        surplusVestingStartTimestamp = block.timestamp;
        _surplusSwept = 0;
    }

    // ============ Withdrawal Queue (V2) ============

    /// @notice Request redemption of sUSDat shares via the withdrawal queue
    /// @dev Transfers shares to the queue, mints an NFT to the caller
    function requestRedeem(uint256 shares, uint256 minSharePrice) external returns (uint256 requestId) {
        require(shares <= maxRedeem(msg.sender), "ExceedsMaxRedeem");

        // Transfer shares from caller to the withdrawal queue
        _transfer(msg.sender, address(queue), shares);

        // Queue creates the request and mints NFT to caller
        requestId = queue.addRequest(msg.sender, shares, minSharePrice);
    }

    /// @notice Returns the address of the WithdrawalQueueERC721 contract
    function getWithdrawalQueue() external view returns (address) {
        return address(queue);
    }

    /// @notice Settles queued shares - burns shares held by queue, sends USDat to queue
    /// @dev Called by MockWithdrawalQueueV2 during processRequests
    function settleQueuedShares(uint256 shares, uint256 usdatAmount) external {
        require(msg.sender == address(queue), "OnlyQueue");

        _sweep();
        _burn(address(queue), shares);
        usdatBalance -= usdatAmount;
        IERC20(asset()).safeTransfer(address(queue), usdatAmount);
    }

    // ============ Test Helpers ============

    /// @notice Process all pending withdrawal requests (test-only)
    function processAllPending() external {
        queue.processAllPending();
    }

    /// @notice Set the deposit fee (test-only)
    function setDepositFeeBps(uint256 feeBps) external {
        depositFeeBps = feeBps;
    }

    /// @notice Directly set USDat balance (test-only, for simulating yield/loss)
    function setUsdatBalance(uint256 amount) external {
        usdatBalance = amount;
    }

    /// @notice Set the surplus vesting period (test-only)
    function setSurplusVestingPeriod(uint256 period) external {
        surplusVestingPeriod = period;
    }
}
