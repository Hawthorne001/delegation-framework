// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeTokenMultiOperationIncreaseBalanceEnforcer
 * @notice Enforces that a recipient's native token balance increases by at least the expected total amount across multiple
 * delegations or decreases by at most the expected total amount across multiple delegations. In a delegation chain,
 * there can be a combination of both increases and decreases, and the enforcer will track the total expected change.
 * @dev Tracks initial balance and accumulates expected increases and decreases per recipient within a redemption
 * @dev This enforcer operates only in default execution mode.
 * @dev Security considerations:
 * - State is shared between enforcers watching the same recipient pair. After transaction execution the state is cleared.
 * - Balance changes are tracked by comparing beforeAll/afterAll balances.
 * - If the delegate is an EOA and not a DeleGator in a situation with multiple delegations, an adapter contract can be used to
 * redeem delegations. An example of this is the src/helpers/DelegationMetaSwapAdapter.sol contract.
 */
contract NativeTokenMultiOperationIncreaseBalanceEnforcer is CaveatEnforcer {
    ////////////////////////////// Events //////////////////////////////

    event TrackedBalance(address indexed delegationManager, address indexed recipient, uint256 balance);
    event UpdatedExpectedBalance(address indexed delegationManager, address indexed recipient, uint256 expected);
    event ValidatedBalance(address indexed delegationManager, address indexed recipient, uint256 expected);

    ////////////////////////////// State //////////////////////////////

    struct BalanceTracker {
        uint256 balanceBefore;
        uint256 expectedIncrease;
        uint256 validationRemaining;
    }

    mapping(bytes32 hashKey => BalanceTracker balance) public balanceTracker;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run, produced by hashing the provided values.
     * @param _caller Address of the sender calling the enforcer.
     * @param _recipient Address of the recipient.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, address _recipient) external pure returns (bytes32) {
        return _getHashKey(_caller, _recipient);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice This function caches the delegator's native token balance before the delegation is executed.
     * @param _terms 52 packed bytes where:
     * - first 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount
     * @param _mode The execution mode. (Must be Default execType)
     */
    function beforeAllHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        (address recipient_, uint256 amount_) = getTermsInfo(_terms);
        require(amount_ > 0, "NativeTokenMultiOperationIncreaseBalanceEnforcer:zero-expected-change-amount");
        bytes32 hashKey_ = _getHashKey(msg.sender, recipient_);

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        if (balanceTracker_.expectedIncrease == 0) {
            balanceTracker_.balanceBefore = recipient_.balance;
            emit TrackedBalance(msg.sender, recipient_, recipient_.balance);
        }

        balanceTracker_.expectedIncrease += amount_;
        balanceTracker_.validationRemaining++;

        balanceTracker[hashKey_] = balanceTracker_;

        emit UpdatedExpectedBalance(msg.sender, recipient_, amount_);
    }

    /**
     * @notice This function enforces that the delegator's native token balance has changed by the expected amount.
     * @param _terms 52 packed bytes where:
     * - first 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount
     */
    function afterAllHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
    {
        (address recipient_,) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, recipient_);

        balanceTracker[hashKey_].validationRemaining--;

        // Only validate on the last afterAllHook if there are multiple enforcers tracking the same recipient pair
        if (balanceTracker[hashKey_].validationRemaining > 0) return;

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        require(
            recipient_.balance >= balanceTracker_.balanceBefore + balanceTracker_.expectedIncrease,
            "NativeTokenMultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"
        );

        emit ValidatedBalance(msg.sender, recipient_, balanceTracker_.expectedIncrease);

        delete balanceTracker[hashKey_];
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms 52 packed bytes where:
     * - first 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount
     * @return recipient_ The address of the recipient whose balance will change.
     * @return amount_ Balance change guardrail amount (i.e., minimum increase)
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address recipient_, uint256 amount_) {
        require(_terms.length == 52, "NativeTokenMultiOperationIncreaseBalanceEnforcer:invalid-terms-length");
        recipient_ = address(bytes20(_terms[0:20]));
        amount_ = uint256(bytes32(_terms[20:]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run, produced by hashing the provided values.
     */
    function _getHashKey(address _caller, address _recipient) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _recipient));
    }
}
