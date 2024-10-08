// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// 1. register VRF subscription
// 2. add consumer into VRF subscription
// 3. consumer -> request random number
// 4. consumer -> receive random number

///////////////////
// Contract: RedPacketDistributor
///////////////////

/**
 * @title RedPacketDistributor
 * @notice Distributes ERC20 tokens to a list of addresses based on a random number generated by Chainlink VRF.
 * @dev This contract uses Chainlink VRF to generate a random number, which is then used to distribute tokens to a list of addresses.
 */
contract RedPacketDistributor is VRFConsumerBaseV2Plus {
    ///////////////////
    // State Variables
    ///////////////////

    uint256 public redPacketCount;
    uint256 private immutable i_subscriptionId; // Subscription ID for the Chainlink VRF service
    address private immutable i_vrfCoordinator; // Sepolia vrfCoordinator
    bytes32 private immutable i_keyHash; // Sepolia Gas LaneGas Lane
    uint32 private immutable i_callbackGasLimit; // Gas limit for the VRF callback function
    uint16 private immutable i_requestConfirmations; // Number of confirmations required for the VRF request
    uint32 private immutable i_numWords; // Number of random words to request

    struct RedPacketInfo {
        uint256 totalAmount;
        uint256 remainingAmount;
        uint256 remainingPackets;
        address erc20;
    }

    mapping(uint256 => RedPacketInfo) public redPackets;
    mapping(address => mapping(uint256 => bool)) public hasClaimed; // 每个地址是否已经领取过特定的红包

    mapping(uint256 => address) public requestToSender;
    mapping(uint256 => uint256) public requestToRedPacketId;

    ///////////////////
    // Events
    ///////////////////
    event RedPacketCreated(uint256 indexed id, uint256 totalAmount, uint256 numPackets);
    event RedPacketClaimed(uint256 indexed id, address indexed claimer, uint256 amount, uint256 randomness);
    event RandomnessRequested(uint256 requestId, address roller);

    ///////////////////
    // Constructor
    ///////////////////

    /**
     * @notice Constructor for initializing the RedPacketDistributor contract
     * @param vrfCoordinator The address of the VRF Coordinator
     * @param subscriptionId The subscription ID for the VRF service
     * @param keyHash The key hash for the VRF
     * @param callbackGasLimit The gas limit for the VRF callback
     * @param requestConfirmations The number of confirmations required for the VRF request
     * @param numWords The number of random words to request
     */
    constructor(
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_vrfCoordinator = vrfCoordinator;
        i_subscriptionId = subscriptionId;
        i_keyHash = keyHash;
        i_callbackGasLimit = callbackGasLimit;
        i_requestConfirmations = requestConfirmations;
        i_numWords = numWords;
    }

    ///////////////////
    // External Functions
    ///////////////////

    /**
     * @notice Creates a new red packet with the specified number of packets and total amount
     * @param numPackets The number of packets to create
     * @param _erc20 The address of the ERC20 token
     * @param _amount The total amount of tokens to distribute
     */
    function createRedPacket(uint256 numPackets, address _erc20, uint256 _amount) external {
        require(_amount > 0, "RedPacket: Amount must be greater than 0");
        require(numPackets > 0, "RedPacket: Number of packets must be greater than 0");
        require(_erc20 != address(0), "RedPacket: ERC20 address cannot be zero");

        // Increment the red packet counter
        redPacketCount++;
        uint256 id = redPacketCount;

        // Transfer ERC20 tokens from the contract owner to the contract
        IERC20 token = IERC20(_erc20);
        require(token.transferFrom(msg.sender, address(this), _amount), "RedPacket: Transfer failed");

        // Create the red packet information
        RedPacketInfo storage rp = redPackets[id];
        rp.totalAmount = _amount;
        rp.remainingAmount = _amount;
        rp.remainingPackets = numPackets;
        rp.erc20 = _erc20;

        emit RedPacketCreated(id, _amount, numPackets);
    }

    /**
     * @notice Claims a red packet by requesting a random number from Chainlink VRF
     * @param redPacketId The ID of the red packet to claim
     * @return requestId The ID of the VRF request
     */
    function claimRedPacket(uint256 redPacketId) external returns (uint256 requestId) {
        RedPacketInfo storage rp = redPackets[redPacketId];
        require(!hasClaimed[msg.sender][redPacketId], "RedPacket: Already claimed");
        require(rp.remainingPackets > 0, "RedPacket: No packets left");

        // Request random number from VRF
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: i_requestConfirmations,
                callbackGasLimit: i_callbackGasLimit,
                numWords: i_numWords,
                // Set nativePayment to true to pay for VRF requests with Sepolia ETH instead of LINK
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );
        requestToSender[requestId] = msg.sender;
        requestToRedPacketId[requestId] = redPacketId;
        emit RandomnessRequested(requestId, msg.sender);
    }

    ///////////////////
    // Internal Functions
    ///////////////////

    /**
     * @notice Fulfills the VRF request by distributing tokens based on the random number
     * @param requestId The ID of the VRF request
     * @param randomWords The array of random words generated by VRF
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        address claimer = requestToSender[requestId];
        uint256 redPacketId = requestToRedPacketId[requestId];

        RedPacketInfo storage rp = redPackets[redPacketId];
        uint256 randomness = randomWords[0];
        uint256 amount = getRandomAmount(rp.remainingAmount, rp.remainingPackets, randomness);
        rp.remainingAmount -= amount;
        rp.remainingPackets--;
        hasClaimed[claimer][redPacketId] = true;

        IERC20 token = IERC20(rp.erc20);
        require(token.transfer(claimer, amount), "RedPacket: Transfer failed");

        emit RedPacketClaimed(redPacketId, claimer, amount, randomness);
    }

    /**
     * @notice Calculates a random amount for the red packet based on the remaining amount and packets
     * @param remainingAmount The total remaining amount in the red packet
     * @param remainingPackets The total number of remaining packets
     * @param randomness The random number generated by VRF
     * @return The calculated amount for the red packet
     */
    function getRandomAmount(uint256 remainingAmount, uint256 remainingPackets, uint256 randomness)
        internal
        pure
        returns (uint256)
    {
        if (remainingPackets == 1) {
            return remainingAmount;
        }

        uint256 maxAmount = (remainingAmount / remainingPackets) * 2;
        return (randomness % maxAmount) + 1;
    }
}
