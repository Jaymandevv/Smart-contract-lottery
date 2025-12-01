//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {VRFConsumerBaseV2Plus} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

// C - Checks
// E - Effects: - internal contact state changes
// I - Interactions - External contract interaction

/**
 * @title A simple Raffle Contract
 * @author Jamiu Garba
 * @notice This contract is for creating a simple raffle
 * @dev Implements Chainlink VRFv2.5
 */
contract Raffle is VRFConsumerBaseV2Plus {
    /* Errors */

    error Raffle__SendMoreToEnterRaffle();
    error Raffle__TransferFailed();
    error Raffle_RaffleNotOpen();
    error Raffle_upkeepNotNeeded(uint256 balance, uint256 playersLength, uint256 raffleState);

    /* Type Declaration */
    enum RaffleState {
        OPEN,
        CALCULATING
    }

    struct Player {
        address payable playerAddress;
        uint256 amountPaid;
        uint256 timeEntered;
    }

    /* State Variables */
    uint16 private constant REQUEST_CONFIRMATION = 3;
    uint32 private constant NUM_WORDS = 1;
    uint256 private immutable I_ENTRANCE_FEE;
    uint256 private immutable I_INTERVAL; // @dev The duration of the lottery in seconds.
    bytes32 private immutable I_KEYHASH; // gas lane
    uint256 private immutable I_SUBSCRIPTION_ID;
    uint32 private immutable I_CALLBACK_GAS_LIMIT;
    Player[] private s_players; //keeps track of players that enter the raffle
    uint256 private s_lastTimeStamp; // Keeps track of the time last raffle ended.
    address private s_recentWinner; // Keeps track of most recent winner
    RaffleState private s_raffleState; // Keeps track of the current state of the raffle contract

    /* EVents */

    event RaffleEntered(address indexed player, uint256 amount, uint256 timeEntered);
    event WinnerPicked(address indexed recentWinner);
    event RequestedRaffleWinner(uint256 indexed requestId);

    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint256 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        I_ENTRANCE_FEE = entranceFee;
        I_INTERVAL = interval;
        I_KEYHASH = gasLane;
        I_SUBSCRIPTION_ID = subscriptionId;
        I_CALLBACK_GAS_LIMIT = callbackGasLimit;

        s_lastTimeStamp = block.timestamp;
        s_raffleState = RaffleState.OPEN;
    }

    function enterRaffle() external payable {
        if (s_raffleState != RaffleState.OPEN) revert Raffle_RaffleNotOpen();

        if (msg.value < I_ENTRANCE_FEE) revert Raffle__SendMoreToEnterRaffle();

        if (s_players.length == 0) {
            s_lastTimeStamp = block.timestamp; // Start timer when first player joins
        }

        Player memory newPlayer =
            Player({playerAddress: payable(msg.sender), amountPaid: msg.value, timeEntered: block.timestamp});
        s_players.push(newPlayer);
        emit RaffleEntered(msg.sender, msg.value, block.timestamp);
    }

    /**
     * @dev This is the function that the Chainlink nodes will call to see
     * if the lottery is ready to have a winner picked.
     * The following should be true in order for the upkeepNeeded to be true:
     * 1. The time interval has passed between raffle
     * 2. The lottery is open
     * 3. The contract has ETH
     * 4. Implicitly, your subscription has LINK
     * @param - ignored
     * @return upkeepNeeded - true if it's time to restart the lottery
     * @return -ignored
     */
    function checkUpkeep(bytes memory /*checkData */ )
        public
        view
        returns (bool upkeepNeeded, bytes memory /*performData */ )
    {
        bool timeHasPassed = (block.timestamp - s_lastTimeStamp) >= I_INTERVAL;
        bool isOPen = s_raffleState == RaffleState.OPEN;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;

        upkeepNeeded = timeHasPassed && isOPen && hasBalance && hasPlayers;
        return (upkeepNeeded, "");
    }

    function performUpkeep(bytes calldata /*perfromData*/ ) external {
        // revert if enough time have not passed
        // if (block.timestamp - s_lastTimeStamp < I_INTERVAL) {
        //     revert();
        // }
        (bool upkeepNeeded,) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Raffle_upkeepNotNeeded(address(this).balance, s_players.length, uint256(s_raffleState));
        }
        s_raffleState = RaffleState.CALCULATING;

        VRFV2PlusClient.RandomWordsRequest memory request = VRFV2PlusClient.RandomWordsRequest({
            keyHash: I_KEYHASH,
            subId: I_SUBSCRIPTION_ID,
            requestConfirmations: REQUEST_CONFIRMATION,
            callbackGasLimit: I_CALLBACK_GAS_LIMIT,
            numWords: NUM_WORDS,
            extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false})) // Set 'nativePayment' to true to pay for VRF requests with sepolia ETH(or blockchain token) instead of LINK
        });

        uint256 requestId = s_vrfCoordinator.requestRandomWords(request);
        emit RequestedRaffleWinner(requestId); // Redundant because the vrfcoordinatoor is emitting the same event
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        // s_players = 10
        // randomNumber = 12
        // winnerIndex = 12 % 10 = 2

        // Effects
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        Player memory recentWinner = s_players[indexOfWinner];
        s_recentWinner = recentWinner.playerAddress;
        s_raffleState = RaffleState.OPEN;
        delete s_players; // Resets the players array
        s_lastTimeStamp = block.timestamp; // Set the timestamp to the current time
        emit WinnerPicked(s_recentWinner);

        // Interactions
        (bool success,) = s_recentWinner.call{value: address(this).balance}("");
        if (!success) revert Raffle__TransferFailed();
    }

    /**
     * Getter Functions
     */
    function getEntranceFee() external view returns (uint256) {
        return I_ENTRANCE_FEE;
    }

    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
    }

    function getPlayer(uint256 indexOfPlayer) external view returns (Player memory) {
        return s_players[indexOfPlayer];
    }

    function getPlayers() external view returns (Player[] memory) {
        return s_players;
    }

    function getLastTimestamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getInterval() external view returns (uint256) {
        return I_INTERVAL;
    }

    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }
}
