// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";

/**
 * @title Lucky Duck Pack - Lucky Draw
 *
 * @notice This contract provides a transparent and verifiable mechanism
 * for conducting lucky draws or giveaways.
 * It uses the Chainlink Verifiable Random Function (VRF) to ensure the
 * randomness used for determining winners is reliable and tamper-proof.
 * The mechanism works as follows:
 * 1. An administrator initiates a draw by invoking the `requestRandomDraw`
 *    function, supplying a data hash representing the draw's unique context
 *    (e.g., participants list, etc.), along with the total number of participants
 *    and desired number of winners. The data hash ensures the draw's context
 *    is unalterable after initiation.
 * 2. A request is made to the Chainlink VRF for a random number. Upon this
 *    request, a unique request ID is returned and associated with the draw's
 *    data hash. Draw details are stored and an event is emitted.
 * 3. The Chainlink VRF responds with a random number, which is then linked to
 *    the specific draw request ID through the `fulfillRandomness` function
 *    (the callback for the Chainlink VRF). The draw information is updated
 *     with the random number, and a `DrawFulfilled` event is emitted.
 * 4. After fulfillment, the winners can be fetched using the `getDrawInfo`
 *    function. This function takes a draw's index, and if the draw is fulfilled,
 *    it calculates and returns the winner(s) based on the random number.
 *
 * This contract is an effective solution for use cases involving random winner
 * selection in a large group of participants, like lucky draws or giveaways,
 * where transparency, fairness, and verifiability are paramount.
 */

contract LDPLuckyDraw is
    Ownable,        // Admin role
    VRFConsumerBase // Chainlink Random
{
    /**
     * @dev Holds information about a specific draw, including
     * its timestamp, the number of participants, winners, and
     * the random number generated by Chainlink VRF.
     */
    struct DrawInfo {
        uint64 requestTimestamp;
        uint32 numParticipants;
        uint32 numWinners;
        uint128 randomness;
    }

    // =============================================================
    //                      CHAINLINK CONSTANTS
    // =============================================================

    // LINK token contract
    address private constant _LINKTOKEN = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    // Chainlink VRF contract
    address private constant _VRFCOORDINATOR = 0xf0d54349aDdcf704F77AE15b96510dEA15cb7952;
    // 2 LINK fee on Ethereum Mainnet
    uint256 private constant _CHAINLINKFEE = 2 ether;
    // Key hash required by Chainlink VRF
    bytes32 private constant _CHAINLINKKEYHASH = 0xAA77729D3466CA35AE8D28B3BBAC7CC36A5031EFDC430821C02BC31A238AF445;

    // =============================================================
    //               CONTRACT VARIABLES AND CONSTANTS
    // =============================================================

    // Constants
    uint128 MAX_UINT128 = 2 ** 128 - 1;

    // Variables
    bytes32[] private _drawsDataHashes;
    mapping(bytes32 => bytes32) private _drawRequestId; // Draw data hash => Chainlink request ID
    mapping(bytes32 => DrawInfo) private _drawInfo; // Chainlink request ID => Draw Info
    mapping(bytes32 => bool) private _fulfilled; // Chainlink request ID => Fulfilled by Chainlink

    // =============================================================
    //                       EVENTS AND ERRORS
    // =============================================================

    /**
     * @dev Emitted when a draw request is made, specifying the data hash
     * and corresponding Chainlink request ID.
     */
    event DrawRequested(bytes32 dataHash, bytes32 chainlinkRequestId);

    /**
     * @dev Emitted when Chainlink VRF fulfills a draw request, specifying
     * the Chainlink request ID and the generated random number.
     */
    event DrawFulfilled(bytes32 chainlinkRequestId, uint128 randomness);

    /**
     * @dev Thrown when a draw request is made for a data hash that has
     * already been requested.
     */
    error AlreadyRequested(bytes32 drawDataHash);

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    /**
     * @dev Initialize the VRF module to work with Chainlink;
     * store the deployer's address; set the provenance timestamp.
     */
    constructor()
        VRFConsumerBase(
            _VRFCOORDINATOR, // Chainlink VRF Coordinator
            _LINKTOKEN // LINK Token address
        )
    {}

    // =============================================================
    //               FUNCTIONS - DRAW REQUEST/FULFILL
    // =============================================================

    /**
     * @notice Triggers a random draw by sending a request to the
     * Chainlink VRF (Verifiable Random Function).
     * The function uses a unique data hash for each draw which is
     * computed by hashing all relevant draw data, such as the list
     * of participants, thereby ensuring that the draw's associated
     * data cannot be altered post-initiation, providing a level of
     * transparency and verifiability.
     * Along with the data hash, the function takes the number of
     * participants and desired number of winners.
     * Upon successful request, the data hash, request ID, and draw
     * details are stored.
     * The random number required to decide the draw's winner(s) is
     * provided by Chainlink in a subsequent transaction.
     * Note: Only the contract owner has the permission to initiate
     * a draw.
     *
     * @param dataHash The value resulting from hashing the draw
     * information (participants list, etc.), ensures draw data
     * remains unalterable
     * @param numParticipants The total number of participants in
     * the draw
     * @param numWinners The number of winners to be chosen from
     * the participants
     */
    function requestRandomDraw(
        bytes32 dataHash,
        uint32 numParticipants,
        uint32 numWinners
    ) external onlyOwner {
        // Check if a draw request has already been made with the given data hash
        if (_drawRequestId[dataHash].length != 0) revert AlreadyRequested(dataHash);
        // Store the data hash
        _drawsDataHashes.push(dataHash);
        // Request randomness from the Chainlink VRF
        bytes32 requestId = requestRandomness(_CHAINLINKKEYHASH, _CHAINLINKFEE);
        // Store the request ID and the details of the draw
        _drawRequestId[dataHash] = requestId;
        _drawInfo[requestId] = DrawInfo({
            requestTimestamp: uint64(block.timestamp),
            numParticipants: numParticipants,
            numWinners: numWinners,
            randomness: 0
        });
        // Emit an event indicating a draw request has been made
        emit DrawRequested(dataHash, requestId);
    }

    /**
     * @notice This function serves as the callback for the Chainlink
     * VRF (Verifiable Random Function) to deliver the requested random
     * number. The random number is used to determine the winner(s) of
     * a draw initiated by the requestRandomDraw function.
     * This function is automatically called by Chainlink upon readying
     * the random number, thereby linking the random number to the
     * specific draw request ID.
     * After receiving the random number, the function stores the received
     * value in the draw's information and emits a DrawFulfilled event to
     * inform the network of the completed request.
     * Note: Chainlink's protocol ensures this function can only be
     * executed by Chainlink's system.
     *
     * @param requestId The unique request ID that was returned by the
     * requestRandomDraw function
     * @param randomness The random number provided by Chainlink VRF
     */
    function fulfillRandomness(
        bytes32 requestId,
        uint256 randomness
    ) internal override {
        // Cast the received randomness to a uint128
        uint128 randomnessCast = uint128(randomness % MAX_UINT128);
        // Store the randomness in the draw's information
        _drawInfo[requestId].randomness = randomnessCast;
        // Mark the draw as fulfilled
        _fulfilled[requestId] = true;
        // Emit an event indicating the draw has been fulfilled
        emit DrawFulfilled(requestId, randomnessCast);
    }

    // =============================================================
    //                      GETTER FUNCTIONS
    // =============================================================

    /**
     * @notice This function allows the retrieval of detailed information
     * about a specific draw by providing the draw's index.
     * If the draw has been fulfilled (i.e., the random number has been
     * returned by Chainlink), the function also calculates and returns
     * the winner(s) based on the random number.
     * Note: The function reverts if a query is made for a non-existent draw.
     *
     * @param drawIndex The index of the draw in the list of all draws
     * @return dataHash The hashed data related to the draw
     * @return requestTimestamp The time when the draw request was made
     * @return chainlinkRequestId The unique ID provided by Chainlink for
     * the random number request
     * @return winners The array of winner IDs if the draw has been
     * fulfilled, otherwise empty
     */
    function getDrawInfo(uint256 drawIndex) external view
        returns (
            bytes32 dataHash,
            uint64 requestTimestamp,
            bytes32 chainlinkRequestId,
            uint256[] memory winners
        )
    {
        // Check if the drawIndex is valid
        require(
            drawIndex < _drawsDataHashes.length,
            "Query for non-existent draw"
        );
        // Retrieve the dataHash and Chainlink request ID for the given drawIndex
        dataHash = _drawsDataHashes[drawIndex];
        chainlinkRequestId = _drawRequestId[dataHash];
        // Retrieve the draw information associated with the Chainlink request ID
        DrawInfo memory drawInfo = _drawInfo[chainlinkRequestId];
        // Extract the timestamp when the draw request was made
        requestTimestamp = drawInfo.requestTimestamp;
        // If the draw has been fulfilled (i.e., the random number has been returned
        // by Chainlink), calculate and return the winners
        if (_fulfilled[chainlinkRequestId]) {
            winners = _getWinnersFromRandomness(
                drawInfo.randomness,
                drawInfo.numParticipants,
                drawInfo.numWinners
            );
        }
    }

    /**
     * @notice This function fetches the data hashes for all the
     * draw requests made on the contract till date. Each data hash
     * uniquely identifies a draw request.
     * 
     * @return An array of data hashes corresponding to all the draw
     * requests made so far
     */
    function getAllDrawsDataHashes() external view returns (bytes32[] memory) {
        bytes32[] memory hashes = _drawsDataHashes;
        return hashes;
    }

    // =============================================================
    //                       PRIVATE FUNCTIONS
    // =============================================================

    /**
     * @dev Generates a list of winners based on the provided random number.
     * @param randomness A random number provided by the Chainlink VRF
     * @param numParticipants The total number of participants in the draw
     * @param numWinners The number of winners to be chosen from the participants
     * @return winnerIds An array of indices for the winners
     */
    function _getWinnersFromRandomness(
        uint128 randomness,
        uint256 numParticipants,
        uint256 numWinners
    ) private pure returns (uint256[] memory winnerIds) {
        for (uint256 i; i < numWinners; ) {
            winnerIds[i] =
                uint256(keccak256(abi.encode(randomness, i))) %
                numParticipants;
            unchecked {++i;}
        }
    }
}

// Quack! :)