// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/**
 * @title TieredTimelock
 * @notice Standalone timelock with per-(target, selector) configurable delays. Designed to be the
 *         single owner/governor of every contract in a protocol stack.
 *
 * Operating model:
 *   - PROPOSER schedules a call: schedule(target, data, predecessor, salt)
 *     → executableAt = now + delayOf[target, selector]
 *   - After executableAt and within grace period: anyone can execute the proposal
 *   - CANCELLER can cancel a pending proposal before it executes
 *   - For selectors with delayOf == 0, PROPOSER can call execute() directly without schedule
 *
 * Self-governance:
 *   - increaseDelay(target, selector, newDelay): delayed by its own selector's delay (0 by default)
 *   - decreaseDelay(target, selector, newDelay): delayed by the TARGET selector's CURRENT delay,
 *     so a delay can NEVER be reduced faster than it currently holds
 *   - addProposer / removeProposer / addCanceller / removeCanceller / updateGracePeriod:
 *     each delayed by its own selector's delay
 *
 * Initialization:
 *   - Deployer is the initial admin with the right to call seedDelay(), setting starting state
 *     without going through the schedule flow.
 *   - After seeding, admin MUST call renounceAdmin() to make the contract fully self-governing.
 *     `renounceAdmin` refuses to renounce until critical role-change delays have been seeded.
 *
 * ETH-input proposals:
 *   Proposals can carry ETH via the `value` parameter. The value is part of the proposal hash,
 *   so the amount forwarded to the target is fixed at schedule time. At execute time, the
 *   timelock forwards exactly `value` to the target; msg.value is optional and treated as
 *   additional funding for the timelock's own balance. Excess msg.value beyond what the call
 *   consumes remains in the timelock and can be swept via a governance proposal.
 *
 *   For proposals with a variable native-token fee (e.g., LayerZero bridging), the proposer
 *   should either (a) schedule with a conservative upper-bound value and rely on the target
 *   to refund excess to msg.sender = timelock, or (b) route through a helper contract that
 *   queries the live fee at execute time.
 *
 * Encoding for proposal IDs:
 *   id = keccak256(abi.encode(target, value, data, predecessor, salt))
 *   executableAt[id]:
 *     0   = never scheduled (or cancelled)
 *     1   = executed (DONE_MARKER)
 *     >1  = scheduled, becomes executable at that block timestamp
 */
contract TieredTimelock is ReentrancyGuard, ERC721Holder, ERC1155Holder {
    using EnumerableSet for EnumerableSet.AddressSet;

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                           CONSTANTS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /// @notice Upper bound on any selector's configurable delay.
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Lower bound on grace period.
    uint256 public constant MIN_GRACE_PERIOD = 1 days;

    /// @notice Upper bound on grace period.
    uint256 public constant MAX_GRACE_PERIOD = 30 days;

    /// @dev Sentinel value stored in `executableAt` to mark an executed proposal.
    uint256 private constant DONE_MARKER = uint256(1);

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                            STORAGE
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /// @notice Address authorized to seed initial state. Zero after renounceAdmin().
    address public admin;

    /// @notice (target, selector) → minimum delay in seconds. Zero = instant execution.
    mapping(bytes32 key => uint256 delay) public delayOf;

    /// @notice proposal id → block timestamp at which the proposal becomes executable.
    ///         0 = never scheduled (or cancelled). 1 = executed (DONE_MARKER). >1 = pending.
    mapping(bytes32 id => uint256) public executableAt;

    /// @notice Time window after `executableAt` during which a matured proposal may still be
    ///         executed. Past that window, the proposal expires and must be re-scheduled.
    uint256 public gracePeriod;

    /// @dev Set of proposers (can call schedule()).
    EnumerableSet.AddressSet private proposers;

    /// @dev Set of cancellers (can call cancel()).
    EnumerableSet.AddressSet private cancellers;

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                            EVENTS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    event Scheduled(
        bytes32 indexed id,
        address indexed target,
        uint256 value,
        bytes data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 executableAt
    );
    event Executed(bytes32 indexed id, address indexed target, uint256 value, bytes data);
    event Cancelled(bytes32 indexed id, address indexed canceller);
    event DelaySet(address indexed target, bytes4 indexed selector, uint256 oldDelay, uint256 newDelay);
    event ProposerSet(address indexed proposer, bool allowed);
    event CancellerSet(address indexed canceller, bool allowed);
    event GracePeriodSet(uint256 oldPeriod, uint256 newPeriod);
    event AdminRenounced();

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                            ERRORS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    error NotProposer();
    error NotCanceller();
    error NotAdmin();
    error NotSelf();
    error ZeroAddress();
    error ZeroSelector();
    error DelayTooLong();
    error DelayNotIncreasing();
    error DelayNotDecreasing();
    error GracePeriodOutOfBounds();
    error AlreadyScheduled();
    error NotScheduled();
    error PredecessorNotDone();
    error TimelockNotExpired();
    error ProposalExpired();
    error MustSchedule();
    error CallFailed(bytes returnData);
    error CannotRemoveLastProposer();
    error CannotRemoveLastCanceller();
    error AlreadyRoleMember();
    error NotRoleMember();
    error CriticalDelayNotSeeded(bytes4 selector);
    error AlreadySeeded(address target, bytes4 selector);

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                          MODIFIERS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    modifier onlyProposer() {
        if (!proposers.contains(msg.sender)) revert NotProposer();
        _;
    }

    modifier onlyCanceller() {
        if (!cancellers.contains(msg.sender)) revert NotCanceller();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev Self-governance: only callable as the result of a scheduled & executed proposal.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                         CONSTRUCTOR
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @param admin_             Initial admin (allowed to seed delays, then must renounce).
     * @param initialProposers_  Addresses granted PROPOSER on day 0 (typically the governor Safe).
     * @param initialCancellers_ Addresses granted CANCELLER on day 0 (Safe + security council).
     * @param gracePeriod_       Initial grace period (must be in [MIN_GRACE_PERIOD, MAX_GRACE_PERIOD]).
     */
    constructor(
        address admin_,
        address[] memory initialProposers_,
        address[] memory initialCancellers_,
        uint256 gracePeriod_
    ) {
        if (admin_ == address(0)) revert ZeroAddress();
        if (gracePeriod_ < MIN_GRACE_PERIOD || gracePeriod_ > MAX_GRACE_PERIOD) revert GracePeriodOutOfBounds();

        admin = admin_;
        gracePeriod = gracePeriod_;
        emit GracePeriodSet(0, gracePeriod_);

        for (uint256 _i; _i < initialProposers_.length; ++_i) {
            address _p = initialProposers_[_i];
            if (_p == address(0)) revert ZeroAddress();
            if (!proposers.add(_p)) revert AlreadyRoleMember();
            emit ProposerSet(_p, true);
        }
        if (proposers.length() == 0) revert CannotRemoveLastProposer();

        for (uint256 _i; _i < initialCancellers_.length; ++_i) {
            address _c = initialCancellers_[_i];
            if (_c == address(0)) revert ZeroAddress();
            if (!cancellers.add(_c)) revert AlreadyRoleMember();
            emit CancellerSet(_c, true);
        }
        if (cancellers.length() == 0) revert CannotRemoveLastCanceller();
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                       VIEW HELPERS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /// @notice Compute the proposal id used internally as the key in `executableAt`.
    function hashProposal(
        address target_,
        uint256 value_,
        bytes calldata data_,
        bytes32 predecessor_,
        bytes32 salt_
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target_, value_, data_, predecessor_, salt_));
    }

    /// @notice Compute the (target, selector) storage key for `delayOf`.
    function delayKey(address target_, bytes4 selector_) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(target_, selector_));
    }

    /// @notice True if the proposal is scheduled but not yet executed or cancelled.
    function isPending(bytes32 id_) public view returns (bool) {
        return executableAt[id_] > DONE_MARKER;
    }

    /// @notice True if the proposal has been executed.
    function isDone(bytes32 id_) public view returns (bool) {
        return executableAt[id_] == DONE_MARKER;
    }

    /// @notice True if the proposal is matured (executableAt passed) AND still within grace period.
    function isReady(bytes32 id_) public view returns (bool) {
        uint256 _at = executableAt[id_];
        return _at > DONE_MARKER && _at <= block.timestamp && block.timestamp <= _at + gracePeriod;
    }

    /// @notice True if `account_` is a proposer.
    function isProposer(address account_) external view returns (bool) {
        return proposers.contains(account_);
    }

    /// @notice True if `account_` is a canceller.
    function isCanceller(address account_) external view returns (bool) {
        return cancellers.contains(account_);
    }

    /// @notice Number of active proposers.
    function proposerCount() external view returns (uint256) {
        return proposers.length();
    }

    /// @notice Number of active cancellers.
    function cancellerCount() external view returns (uint256) {
        return cancellers.length();
    }

    /// @notice All current proposer addresses.
    function getProposers() external view returns (address[] memory) {
        return proposers.values();
    }

    /// @notice All current canceller addresses.
    function getCancellers() external view returns (address[] memory) {
        return cancellers.values();
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                      SCHEDULE / EXECUTE
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Schedule a proposal. Proposer-only. `executableAt` is computed from `delayOf`.
     *         For proposals targeting this contract's own `decreaseDelay`, `executableAt` uses the
     *         TARGET selector's current delay so a delay reduction cannot be fast-pathed.
     *
     *         `value_` is the exact ETH amount the target will receive at execute time. It is part
     *         of the proposal hash, so it cannot be changed after scheduling.
     */
    function schedule(
        address target_,
        uint256 value_,
        bytes calldata data_,
        bytes32 predecessor_,
        bytes32 salt_
    ) external onlyProposer returns (bytes32 _id) {
        if (target_ == address(0)) revert ZeroAddress();
        if (data_.length < 4) revert ZeroSelector();

        bytes4 _sel = bytes4(data_[:4]);
        uint256 _delay = _resolveDelay(target_, _sel, data_);

        _id = hashProposal(target_, value_, data_, predecessor_, salt_);
        if (executableAt[_id] != 0) revert AlreadyScheduled();

        uint256 _at = block.timestamp + _delay;
        executableAt[_id] = _at;

        emit Scheduled(_id, target_, value_, data_, predecessor_, salt_, _at);
    }

    /**
     * @notice Execute a previously scheduled proposal. Permissionless after `executableAt`.
     *         When `delayOf[target, selector] == 0` and no schedule exists, the proposer may
     *         execute in a single tx without scheduling first.
     *
     *         `value_` must match the value used at schedule time. The timelock forwards
     *         exactly `value_` to the target; the ETH may come from msg.value attached to this
     *         call, from the timelock's pre-existing balance, or a combination. Any msg.value
     *         beyond what the call uses stays in the timelock.
     *
     *         If `predecessor_ != 0`, that proposal must be `done` before this one can execute.
     */
    function execute(
        address target_,
        uint256 value_,
        bytes calldata data_,
        bytes32 predecessor_,
        bytes32 salt_
    ) external payable nonReentrant returns (bytes memory) {
        if (target_ == address(0)) revert ZeroAddress();
        if (data_.length < 4) revert ZeroSelector();

        bytes32 _id = hashProposal(target_, value_, data_, predecessor_, salt_);
        uint256 _at = executableAt[_id];

        if (_at == 0) {
            // Not scheduled: only allowed if delay is 0 AND caller is a proposer.
            bytes4 _sel = bytes4(data_[:4]);
            uint256 _delay = _resolveDelay(target_, _sel, data_);
            if (_delay != 0) revert MustSchedule();
            if (!proposers.contains(msg.sender)) revert NotProposer();
        } else if (_at == DONE_MARKER) {
            revert AlreadyScheduled();
        } else {
            if (block.timestamp < _at) revert TimelockNotExpired();
            if (block.timestamp > _at + gracePeriod) revert ProposalExpired();
        }

        if (predecessor_ != bytes32(0) && executableAt[predecessor_] != DONE_MARKER) {
            revert PredecessorNotDone();
        }

        // Mark done BEFORE the external call (CEI).
        executableAt[_id] = DONE_MARKER;

        (bool _ok, bytes memory _ret) = target_.call{value: value_}(data_);
        if (!_ok) revert CallFailed(_ret);

        emit Executed(_id, target_, value_, data_);
        return _ret;
    }

    /**
     * @notice Cancel a pending proposal. Callable by any canceller.
     *         Cannot cancel done or never-scheduled proposals.
     */
    function cancel(bytes32 id_) external onlyCanceller {
        uint256 _at = executableAt[id_];
        if (_at == 0 || _at == DONE_MARKER) revert NotScheduled();
        delete executableAt[id_];
        emit Cancelled(id_, msg.sender);
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                  SELF-GOVERNED CONFIGURATION
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Raise the delay for a (target, selector). Scheduling delay = its own selector's delay
     *         (default 0 → instant initially; raise this delay first to slow down future increases).
     */
    function increaseDelay(address target_, bytes4 selector_, uint256 newDelay_) external onlySelf {
        if (newDelay_ > MAX_DELAY) revert DelayTooLong();
        bytes32 _key = delayKey(target_, selector_);
        uint256 _old = delayOf[_key];
        if (newDelay_ <= _old) revert DelayNotIncreasing();
        delayOf[_key] = newDelay_;
        emit DelaySet(target_, selector_, _old, newDelay_);
    }

    /**
     * @notice Lower the delay for a (target, selector). Scheduling delay = TARGET selector's CURRENT
     *         delay, so a delay can never be reduced faster than it currently holds.
     */
    function decreaseDelay(address target_, bytes4 selector_, uint256 newDelay_) external onlySelf {
        bytes32 _key = delayKey(target_, selector_);
        uint256 _old = delayOf[_key];
        if (newDelay_ >= _old) revert DelayNotDecreasing();
        delayOf[_key] = newDelay_;
        emit DelaySet(target_, selector_, _old, newDelay_);
    }

    /// @notice Add a proposer. Self-governed. Reverts if already a member.
    function addProposer(address account_) external onlySelf {
        if (account_ == address(0)) revert ZeroAddress();
        if (!proposers.add(account_)) revert AlreadyRoleMember();
        emit ProposerSet(account_, true);
    }

    /// @notice Remove a proposer. Reverts if this would leave zero proposers (would brick timelock).
    function removeProposer(address account_) external onlySelf {
        if (proposers.length() <= 1) revert CannotRemoveLastProposer();
        if (!proposers.remove(account_)) revert NotRoleMember();
        emit ProposerSet(account_, false);
    }

    /// @notice Add a canceller. Self-governed. Reverts if already a member.
    function addCanceller(address account_) external onlySelf {
        if (account_ == address(0)) revert ZeroAddress();
        if (!cancellers.add(account_)) revert AlreadyRoleMember();
        emit CancellerSet(account_, true);
    }

    /// @notice Remove a canceller. Reverts if this would leave zero cancellers (defense removed).
    function removeCanceller(address account_) external onlySelf {
        if (cancellers.length() <= 1) revert CannotRemoveLastCanceller();
        if (!cancellers.remove(account_)) revert NotRoleMember();
        emit CancellerSet(account_, false);
    }

    /// @notice Update the grace period. Self-governed.
    function updateGracePeriod(uint256 newGracePeriod_) external onlySelf {
        if (newGracePeriod_ < MIN_GRACE_PERIOD || newGracePeriod_ > MAX_GRACE_PERIOD) {
            revert GracePeriodOutOfBounds();
        }
        uint256 _old = gracePeriod;
        gracePeriod = newGracePeriod_;
        emit GracePeriodSet(_old, newGracePeriod_);
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                  ADMIN (ONE-TIME SEEDING)
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice One-time setup: configure the initial delay for a (target, selector).
     *         Set-once: reverts with `AlreadySeeded` if the key already has a non-zero delay.
     *         (After the initial seed, subsequent changes must go through `increaseDelay` /
     *         `decreaseDelay` like every other update.) Capped by MAX_DELAY. Only callable
     *         while admin is set.
     */
    function seedDelay(address target_, bytes4 selector_, uint256 delay_) external onlyAdmin {
        if (target_ == address(0)) revert ZeroAddress();
        if (delay_ > MAX_DELAY) revert DelayTooLong();
        bytes32 _key = delayKey(target_, selector_);
        if (delayOf[_key] != 0) revert AlreadySeeded(target_, selector_);
        delayOf[_key] = delay_;
        emit DelaySet(target_, selector_, 0, delay_);
    }

    /**
     * @notice Renounce admin role. IRREVERSIBLE. After this, delays / roles / grace period can
     *         only be changed via the schedule → execute flow.
     *
     *         Refuses to renounce while critical role-change and config selectors have delay = 0,
     *         since those functions would otherwise be permanently single-tx-callable by any
     *         compromised proposer. Guarantees the contract enters self-governance in a safe state.
     */
    function renounceAdmin() external onlyAdmin {
        _requireCriticalDelaySet(TieredTimelock.addProposer.selector);
        _requireCriticalDelaySet(TieredTimelock.removeProposer.selector);
        _requireCriticalDelaySet(TieredTimelock.addCanceller.selector);
        _requireCriticalDelaySet(TieredTimelock.removeCanceller.selector);
        _requireCriticalDelaySet(TieredTimelock.increaseDelay.selector);
        _requireCriticalDelaySet(TieredTimelock.updateGracePeriod.selector);

        admin = address(0);
        emit AdminRenounced();
    }

    /// @dev Reverts if the (self, selector) delay has not been seeded.
    function _requireCriticalDelaySet(bytes4 selector_) private view {
        if (delayOf[delayKey(address(this), selector_)] == 0) {
            revert CriticalDelayNotSeeded(selector_);
        }
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                            HELPERS
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /**
     * @dev Resolves the delay that should be applied at schedule-time.
     *      Special case: `this.decreaseDelay(target, selector, newDelay)` uses the TARGET selector's
     *      CURRENT delay, so a delay can never be reduced faster than it currently holds.
     */
    function _resolveDelay(
        address target_,
        bytes4 sel_,
        bytes calldata data_
    ) private view returns (uint256) {
        if (target_ == address(this) && sel_ == this.decreaseDelay.selector) {
            // decreaseDelay(address, bytes4, uint256)
            // data layout: [4-byte selector][32-byte target][32-byte selector word][32-byte newDelay]
            if (data_.length < 4 + 32 + 32 + 32) revert ZeroSelector();
            address _targetArg = address(uint160(uint256(bytes32(data_[4:36]))));
            bytes4 _selArg = bytes4(data_[36:40]);
            return delayOf[delayKey(_targetArg, _selArg)];
        }
        return delayOf[delayKey(target_, sel_)];
    }

    /* ════════════════════════════════════════════════════════════════════════════════════════
                                          ETH HANDLING
    ════════════════════════════════════════════════════════════════════════════════════════ */

    /// @notice Allow the contract to receive ETH so it can forward msg.value to payable targets.
    receive() external payable {}
}
