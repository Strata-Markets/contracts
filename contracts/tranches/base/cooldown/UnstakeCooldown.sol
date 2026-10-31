// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IUnstakeHandler } from "../../interfaces/cooldown/IUnstakeHandler.sol";
import { IUnstakeCooldown } from "../../interfaces/cooldown/ICooldown.sol";
import { CooldownBase } from "./CooldownBase.sol";

/**
 * @title Strata Unstake Cooldown Manager
 */
contract UnstakeCooldown is IUnstakeCooldown, CooldownBase {

    event UserProxyCreated(address indexed user, address proxy);
    event UserProxyImplementationSet(address token, address impl);

    struct TRequest {
        uint64 unlockAt;
        IUnstakeHandler proxy;
    }

    /// @dev Unstaking implementations for each supported token and protocol
    mapping(address token => IUnstakeHandler unstakeImpl) public implementations;

    /// @dev Active requests
    mapping(address token => mapping(address account => TRequest[] requests)) public activeRequests;

    /// @dev Maintain proxies Pool, after the request is completed, the proxy is returned to the pool
    mapping(address token => mapping(address account => IUnstakeHandler[] proxy)) public proxiesPool;

    /// @notice Transfers assets from msg.sender (Strategy) to the specified user by creating an unstake request in the underlying protocol
    /// @dev After the cooldown period elapses in the underlying protocol,
    /// @dev the requests can be finalized and the funds are unlocked and transferred to the user
    /// @param token The ERC20 token being transferred
    /// @param initialFrom The original sender of the assets, specified by the strategy
    /// @param to The recipient of the unstaked assets
    /// @param amount The amount of tokens to transfer
    /// @custom:access Restricted to COOLDOWN_WORKER_ROLE
    function transfer(IERC20 token, address initialFrom, address to, uint256 amount) external onlyRole(COOLDOWN_WORKER_ROLE) {
        address worker = msg.sender;
        if (amount == 0) {
            return;
        }
        address impl = address(implementations[address(token)]);
        if (impl == address(0)) {
            revert UnsupportedToken(address(token));
        }

        TRequest[] storage requests = activeRequests[address(token)][to];
        IUnstakeHandler[] storage proxies = proxiesPool[address(token)][to];

        IUnstakeHandler proxy;
        bool shouldReuseRequest = false;
        uint256 requestsCount = requests.length;
        if (initialFrom != to && requestsCount >= PUBLIC_REQUEST_SLOTS_CAP) {
            revert ExternalReceiverRequestLimitReached(token, initialFrom, to, amount);
        }
        if (requestsCount >= MAX_ACTIVE_REQUEST_SLOTS) {
            if (requestsCount == 0 || requests[requestsCount - 1].proxy.requestedAt() != block.timestamp) {
                revert ExternalReceiverRequestLimitReached(token, initialFrom, to, amount);
            }
        }
        if (requestsCount > 0) {
            // Only merge requests initiated within the exact same block
            shouldReuseRequest = requests[requestsCount - 1].proxy.requestedAt() == block.timestamp;
        }
        if (shouldReuseRequest) {
            proxy = requests[requestsCount - 1].proxy;
        } else {
            uint256 len = proxies.length;
            if (len > 0) {
                proxy = IUnstakeHandler(proxies[len - 1]);
                proxies.pop();
                if (impl != getImplementation(address(proxy))) {
                    proxy = createFor(impl, to);
                }
            } else {
                proxy = createFor(impl, to);
            }
        }

        SafeERC20.safeTransferFrom(token, worker, address(proxy), amount);

        uint256 unlockAt = proxy.request();
        emit TransferRequested(token, initialFrom, to, amount, unlockAt);

        if (shouldReuseRequest) {
            if (unlockAt > block.timestamp) {
                // If not an instant transfer, update the existing unlockAt
                requests[requestsCount - 1].unlockAt = uint64(unlockAt);
            }
            // exit, do not modify requests and proxies
            return;
        }
        if (unlockAt <= block.timestamp) {
            // already transferred (instant transfer), return proxy to pool and exit
            proxies.push(proxy);
            emit Finalized(token, to, amount);
            return;
        }
        requests.push(TRequest(uint64(unlockAt), proxy));
    }

    /// @notice Finalizes the requests up to the current block timestamp
    /// @custom:see finalize(IERC20 token, address user, uint256 at) for more detailed documentation
    function finalize(IERC20 token, address user) external returns (uint256 claimed) {
        return finalize(token, user, block.timestamp);
    }

    /// @notice Finalizes unstake requests for a user, processing all eligible requests up to the specified timestamp
    /// @param token The ERC20 token being unstaked
    /// @param user The address of the user whose requests are being finalized
    /// @param at The timestamp up to which requests should be processed
    /// @return claimed The total amount of tokens claimed from finalized requests
    function finalize(IERC20 token, address user, uint256 at) public returns (uint256 claimed) {
        if (at > block.timestamp) {
            revert InvalidTime();
        }
        TRequest[] storage requests = activeRequests[address(token)][user];
        IUnstakeHandler[] storage proxies = proxiesPool[address(token)][user];
        IUnstakeHandler imp = implementations[address(token)];

        // Emergency exit: check the underlying protocol if the cooldown is still active
        bool isCooldownActive = imp.isCooldownActive();
        bool anyFinalized = false;
        uint256 len = requests.length;
        for (uint256 i; i < len; ) {
            TRequest memory req = requests[i];
            if (isCooldownActive && req.unlockAt > at) {
                // Still pending
                unchecked { i++; }
                continue;
            }

            try req.proxy.finalize() returns (uint256 amount) {
                claimed += amount;
                // Return proxy to the pool (reuse later)
                proxies.push(req.proxy);

                if (i < len - 1) {
                    requests[i] = requests[len - 1];
                }
                anyFinalized = true;
                requests.pop();
                unchecked { len--; }
            } catch {
                // Implementation not ready (e.g. Midas assets not yet airdropped)
                // Skip this request — it stays in the array for retry
                unchecked { i++; }
            }
        }
        if (anyFinalized == false) {
            revert NothingToFinalize();
        }

        emit Finalized(token, user, claimed);
        return claimed;
    }

    /// @notice Returns the user's balance state at the current block timestamp
    /// @custom:see balanceOf(IERC20 token, address user, uint256 at) for more detailed documentation
    function balanceOf (IERC20 token, address user) external view returns (TBalanceState memory) {
        return balanceOf(token, user, block.timestamp);
    }

    /// @notice Returns the user's balance state for a given unstakable token at a specific timestamp
    /// @dev Balance includes pending and claimable amounts in underlying tokens
    /// @param token The unstakable token address
    /// @param user The user's address
    /// @param at The timestamp for which to calculate the balance
    /// @return TBalanceState struct containing pending, claimable, and next unlock details in underlying tokens
    function balanceOf (IERC20 token, address user, uint256 at) public view returns (TBalanceState memory) {
        TRequest[] storage requests = activeRequests[address(token)][user];
        IUnstakeHandler imp = implementations[address(token)];
        bool isCooldownActive = imp.isCooldownActive();

        uint256 l = requests.length;

        uint256 pending;
        uint256 claimable;
        uint256 nextUnlockAt;
        uint256 nextUnlockAmount;

        for (uint256 i; i < l; i++) {
            TRequest memory req = requests[i];
            uint256 amount = req.proxy.getPendingAmount();
            if (isCooldownActive && req.unlockAt > at) {
                pending += amount;
                if (nextUnlockAt == 0 || req.unlockAt < nextUnlockAt) {
                    nextUnlockAt = req.unlockAt;
                    nextUnlockAmount = amount;
                    continue;
                }
                if (req.unlockAt == nextUnlockAt) {
                    nextUnlockAmount += amount;
                }
                continue;
            }
            claimable += amount;
        }
        return TBalanceState({
            pending: pending,
            claimable: claimable,
            nextUnlockAt: nextUnlockAt,
            nextUnlockAmount: nextUnlockAmount,
            totalRequests: l
        });
    }

    function createFor(address implementation, address user) internal returns (IUnstakeHandler proxy) {
        proxy = IUnstakeHandler(Clones.clone(implementation, 0));
        proxy.initialize(address(this), user);
        emit UserProxyCreated(user, address(proxy));
        return proxy;
    }

    /**
     * @dev Updates the implementations for tokens. Implementation can be ZERO address in case we want to remove supported token.
     */
    function setImplementations(address[] calldata tokens_, IUnstakeHandler[] calldata implementations_) external onlyOwner {
        uint256 len = tokens_.length;
        for (uint256 i = 0; i < len; ) {
            address token = tokens_[i];
            IUnstakeHandler impl = implementations_[i];
            implementations[token] = impl;
            emit UserProxyImplementationSet(token, address(impl));
            unchecked { i++; }
        }
    }

    function getImplementation(address proxy) internal view returns (address implementation) {
        assembly {
            // Clones.clone := 0x363d3d373d3d3d363d73<20-byte implementation>5af43d82803e903d91602b57fd5bf3
            let ptr := mload(0x40)
            extcodecopy(proxy, ptr, 10, 32)
            implementation := shr(96, mload(ptr)) // right-shift to 20 bytes
        }
    }
}
