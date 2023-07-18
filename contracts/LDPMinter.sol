// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./lib/interfaces/ILDP.sol";

/**
 * @title Lucky Duck Pack Minter
 *
 * @notice This contract manages the LDP collection minting process.
 *
 * We strongly recommend to thoroughly examine the code before interacting
 * with it.
 *
 * To assist in the review process, ample comments have been included
 * throughout the code.
 *
 * Like all other Lucky Duck Pack contracts, this aims to be fair, secure,
 * trustworthy and efficient.
 *
 * This is accomplished through features including:
 * -The administrator's privileges are very limited and, once the minting
 *  process begins, they are further restricted to payout functions only.
 * -Variables such as prices are hardcoded to ensure transparency and lower
 *  gas fees.
 * -Token distribution and reveal are ensured to be fair and secure from
 *  hacking, thanks to the use of Chainlink VRF - Further information can
 *  be found in the NFT contract.
 * -The design of the mint function has been kept minimal to reduce its gas
 *  costs.
 * --------------------------------------------------------------------------
 * SALE MECHANICS EXPLAINED:
 * The minting process that is divided into two main phases: a fixed-price
 * sale and a Dutch auction.
 * -In the fixed-price sale phase, the total supply of tokens is divided into
 * three equal parts, each with a different price. The first third of the
 * tokens is sold at the lowest price, the second third at a median price,
 * and the final third at the highest price.
 * -If the fixed-price sale does not sell out within a certain timeframe,
 * the contract automatically transitions to a Dutch auction. In this auction,
 * the initial price is set to the median price used in the fixed-price sale.
 * The price then decreases over time until either all tokens are sold or the
 * auction reaches a predetermined end price.
 * -If the first Dutch auction does not sell out, a second Dutch auction is
 * initiated after a certain delay. The initial price for the second auction
 * is set to the end price of the first auction. Again, the price decreases
 * over time until all tokens are sold or the auction reaches a predetermined
 * end price.
 * --------------------------------------------------------------------------
 * DISCLAIMER:
 * This smart contract code (the "Software") is provided "as is", without
 * warranty of any kind, express or implied, including but not limited to
 * the warranties of merchantability, fitness for a particular purpose, title
 * and non-infringement. In no event shall the copyright holders or anyone
 * distributing the Software be liable for any damages or other liability,
 * whether in contract, tort or otherwise, arising from, out of, or in
 * connection with the Software or the use or other dealings in the Software.
 *
 * The Software is decentralized and the admin keys have been burned following
 * deployment, meaning the creator no longer has any special privileges, nor
 * the power to fix, alter, or control its behavior.
 *
 * The creator of the Software is not a law firm and this disclaimer does not
 * constitute legal advice. The laws and regulations applicable to smart
 * contracts and blockchain technologies vary by jurisdiction. As such, you
 * are strongly advised to consult with your legal counsel before engaging
 * in any smart contract or blockchain-related activities.
 *
 * The creator of the Software disclaims all responsibility and liability for
 * the accuracy, applicability, or completeness of the Software. Any use or
 * reliance on the Software or any part thereof is strictly at your own risk,
 * and you fully accept and assume all risks associated with any such reliance.
 * This includes, but is not limited to, responsibility for the consequences
 * of any errors, inaccuracies, omissions, or other defects that may be
 * present in the Software.
 *
 * You agree to indemnify and hold harmless the creator of the Software from
 * and against any and all losses, liabilities, claims, damages, costs, and
 * expenses, including legal fees and disbursements, arising out of or
 * resulting from your use of the Software.
 *
 * By using the Software, you acknowledge that you have read and understood
 * this disclaimer, and agree to be bound by its terms.
 * --------------------------------------------------------------------------
 */
contract LDPMinter is Ownable, ReentrancyGuard {

    // =============================================================
    //                         CUSTOM TYPES
    // =============================================================

    /**
     * @dev A struct that contains the parameters for conducting a Dutch Auction. 
     * In a Dutch Auction, the auction starts at a high price which continuously 
     * (or at defined intervals) drops until it reaches a specified resting price or 
     * the auction ends.
     */
    struct DutchAuction {
        uint256 startPrice; // Initial price of the Dutch Auction
        uint256 restingPrice; // End price of the Dutch Auction
        uint256 startTime; // Time at which the price starts decaying
        uint256 endTime; // Time at which the resting price is reached
        uint256 timeStep; // Price update timestep
    }

    // =============================================================
    //                   CONSTANTS / IMMUTABLES
    // =============================================================

    // Prices during the first minting phase (standard sale)
    uint256 private constant _SALE_PRICE1 = 0.25 ether; // Price for tokens 1 to 3333
    uint256 private constant _SALE_PRICE2 = 0.75 ether; // Price for tokens 3334 to 6666
    uint256 private constant _SALE_PRICE3 = 1.25 ether; // Price for tokens 6667 to 10000
    // Resting prices for the second minting phase (Dutch auctions) - auctions kick in if the collection isn't sold out during the first phase
    uint256 private constant _AUCTION1_RESTING_PRICE = 0.075 ether; // Resting price of the first Dutch Auction
    uint256 private constant _AUCTION2_RESTING_PRICE = 0.025 ether; // Resting price of the second Dutch Auction
    // Delays, durations and timestep of the Dutch auctions
    uint256 private constant _AUCTION1_START_DELAY = 2 days;
    uint256 private constant _AUCTION2_START_DELAY = 1 days;
    uint256 private constant _AUCTIONS_DURATION = 1 days;
    uint256 private constant _AUCTIONS_TIMESTEP = 30 minutes;
    // Number of tokens reserved for the team
    uint256 private constant _TEAM_RESERVED = 50;
    // Instance of the token contract
    ILDP public immutable NFT;
    // LDP Rewarder contract address
    address public immutable REWARDER_ADDRESS;

    // =============================================================
    //                     CONTRACT VARIABLES
    // =============================================================

    // Collection creator address
    address private _creator;
    // The time when the minting has started
    uint256 public mintingStartTime;

    // =============================================================
    //                 CUSTOM ERRORS AND EVENTS
    // =============================================================

    event MintingStarted(); // Emitted when the minting is opened

    error InputIsZero(); // Triggered when address(0) is used as a function parameter
    error MintingNotStarted(); // Occurs when trying to mint before mintingStarted is enabled
    error MintingAlreadyStarted(); // Raised when startMinting is called while minting is already in progress
    error MaxMintsPerCallExceeded(); // Happens when attempting to mint more than 10 NFTs at once
    error Underpaid(uint256 paid, uint256 required); // Indicates insufficient payment
    error PaymentError(bool successA, bool successB); // Denotes a transfer error

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    /**
     * @dev Store the NFT contract address; store the Rewarder contract address;
     * initialize the creator address.
     * @param nftContract The address of the LuckyDuckPack NFT contract
     * @param rewarderAddress The address of the LuckyDuckPack Rewarder contract
     * @param creatorAddress The creator's address
     */
    constructor(
        address nftContract,
        address rewarderAddress,
        address creatorAddress
    ) {
        NFT = ILDP(nftContract);
        REWARDER_ADDRESS = rewarderAddress;
        _creator = creatorAddress;
    }

    // =============================================================
    //                     FUNCTIONS - MINTING
    // =============================================================

    /**
     * @notice Mint (buy) tokens to the caller address.
     * @param amount Number of tokens to be minted, max 10 per transaction.
     */
    function mint(uint256 amount) external payable nonReentrant {
        // Revert if minting hasn't started
        if (mintingStartTime == 0) revert MintingNotStarted();
        // Revert if attempting to mint more than 10 tokens at once
        if (amount > 10) revert MaxMintsPerCallExceeded();
        // Revert if underpaying
        uint256 priceTotal = _currentPrice_t6y() * amount;
        unchecked {
            if (msg.value < priceTotal)
                revert Underpaid(msg.value, priceTotal);
        }
        // Finally, mint the tokens
        NFT.mint_Qgo(msg.sender, amount);
    }

    /**
     * @notice Enable minting and mint [_TEAM_RESERVED] tokens to admin's
     * address. Some of these tokens will be used for giveaways, the rest
     * will be gifted to the team.
     * @dev This function can be called only once, so admin won't be able to
     * mint more than [_TEAM_RESERVED] free tokens.
     */
    function startMinting() external onlyOwner {
        if (mintingStartTime != 0) revert MintingAlreadyStarted();
        mintingStartTime = block.timestamp;
        NFT.mint_Qgo(msg.sender, _TEAM_RESERVED);
        emit MintingStarted();
    }

    /**
     * @notice Get how many tokens are left to be minted.
     */
    function mintableSupply() external view returns (uint256 supply) {
        unchecked {
            supply = NFT.MAX_SUPPLY() - NFT.totalSupply();
        }
    }

    /**
     * @notice Get the current price. If the minting hasn't started, returns the initial
     * minting price.
     */
    function currentPrice() external view returns (uint256) {
        if (mintingStartTime == 0) return _SALE_PRICE1;
        return _currentPrice_t6y();
    }

    /**
     * @notice Checks if the minting process has been initiated.
     * @return A boolean value indicating whether the minting process has started or not.
     */
    function mintingStarted() external view returns (bool) {
        return mintingStartTime != 0;
    }

    // =============================================================
    //                    FUNCTIONS - CASH OUT
    // =============================================================

    /**
     * @notice Set/amend the creator address.
     */
    function setCreatorAddress(address creatorAddr) external onlyOwner {
        if (creatorAddr == address(0)) revert InputIsZero();
        _creator = creatorAddr;
    }

    /**
     * @notice Send proceeds to creator address and incentives to Rewarder contract.
     * @dev Reverts if the transfers fail.
     */
    function withdrawProceeds() external {
        // Checks
        if (mintingStartTime == 0) revert MintingNotStarted();
        if (_msgSender() != owner())
            require(
                _msgSender() == _creator,
                "Caller is not admin nor creator"
            );
        // Actual withdraw
        (bool creatorPaid, bool rewarderPaid) = _processWithdraw_SVt();
        // Revert if any payments failed
        if (!(creatorPaid && rewarderPaid))
            revert PaymentError(creatorPaid, rewarderPaid);
    }

    /**
     * @notice Emergency function to recover funds that may be trapped in the contract
     * in the event of unforeseen circumstances preventing {withdrawProceeds} from
     * functioning as intended. This function is subject to strict limitations:
     * it cannot be utilized prior to the completion of the minting process, it
     * initially attempts a regular withdrawal (to prevent potential exploitation by
     * the admin), and only in case that fails, it sends any remaining funds to the
     * admin's address. The admin will then be responsible for distributing the
     * proceeds manually.
     */
    function emergencyWithdraw() external onlyOwner {
        // Revert if the function is called before the minting process ends
        require(
            NFT.totalSupply() == NFT.MAX_SUPPLY(),
            "Minting still in progress"
        );
        // Attempt the normal withdraw first: if succeeds, emergency actions won't be performed
        (bool creatorPaid, bool rewarderPaid) = _processWithdraw_SVt();
        // If any of the two payments failed, send the remaining balance to admin
        if (!(creatorPaid && rewarderPaid)) {
            uint256 _bal = address(this).balance;
            payable(_msgSender()).transfer(_bal);
        }
    }

    // =============================================================
    //                      INTERNAL LOGICS
    // =============================================================

    /**
     * @dev Returns the current price.
     */
    function _currentPrice_t6y() private view returns (uint256) {
        // Copy mint start time to a memory variable to reduce the storage operations (save gas)
        uint256 mintingStart = mintingStartTime;

        // If the first Dutch auction hasn't started, return the initial sale price
        uint256 auction1StartTime; // Initialize auction 1 start time variable
        unchecked {
            auction1StartTime = mintingStart + _AUCTION1_START_DELAY; // Compute auction 1 start time
        }
        if (block.timestamp < auction1StartTime) return _salePrice_gn2();
        // The code from here is executed only if the first auction has started
        // Compute and return price for the first auction
        uint256 auction1EndTime; // Initialize auction 1 end time variable
        unchecked {
            auction1EndTime = auction1StartTime + _AUCTIONS_DURATION; // Compute auction 1 end time
        }
        if (block.timestamp < auction1EndTime) // If auction 1 hasn't ended, return its current price
            return
                _dutchAuctionPrice_Ts0(
                    DutchAuction({
                        startPrice: _SALE_PRICE2, // Auction 1 starts at the median sale price
                        restingPrice: _AUCTION1_RESTING_PRICE,
                        startTime: auction1StartTime,
                        endTime: auction1EndTime,
                        timeStep: _AUCTIONS_TIMESTEP
                    }),
                    block.timestamp
                );
        // The code from here is executed only if the second auction has started
        uint256 auction2StartTime;
        uint256 auction2EndTime;
        unchecked {
            auction2StartTime = auction1EndTime + _AUCTION2_START_DELAY;
            auction2EndTime = auction2StartTime + _AUCTIONS_DURATION;
        }
        return
            _dutchAuctionPrice_Ts0(
                DutchAuction({
                    startPrice: _AUCTION1_RESTING_PRICE, // Auction 2 starts at the Auction 1 resting price
                    restingPrice: _AUCTION2_RESTING_PRICE,
                    startTime: auction2StartTime,
                    endTime: auction2EndTime,
                    timeStep: _AUCTIONS_TIMESTEP
                }),
                block.timestamp
            );
    }

    /**
     * @dev Calculates and returns the current price in a Dutch auction.
     * The price starts at a predefined high value and decreases in discrete steps
     * at regular intervals until the auction ends, or until the price reaches a
     * predefined resting price (whichever happens first).
     *
     * @param _auctionInfo A 'DutchAuction' struct containing information about the auction
     * @param currentTime The current timestamp to be used for price calculation
     * @return The current price
     */
    function _dutchAuctionPrice_Ts0(
        DutchAuction memory _auctionInfo,
        uint256 currentTime
    ) private pure returns (uint256) {
        // If the auction has not started yet (i.e., current time is before the auction start time), return the start price
        if (currentTime < _auctionInfo.startTime)
            return _auctionInfo.startPrice;
        uint256 stepsPassed;
        uint256 priceDecrement;
        // Unchecked block is used to ignore overflow/underflow conditions for more gas-efficient code
        // This is safe in our case, as the first IF statement of this function ensures that the auction has started
        // (i.e., block.timestamp is never less than startTime) by the time this part of the code is executed
        unchecked {
            // Calculate the number of time steps that have passed since the auction started
            stepsPassed =
                (currentTime - _auctionInfo.startTime) /
                _auctionInfo.timeStep;
            // Calculate how much the price should have decreased by now
            priceDecrement =
                ((_auctionInfo.startPrice - _auctionInfo.restingPrice) /
                    ((_auctionInfo.endTime - _auctionInfo.startTime) /
                        _auctionInfo.timeStep)) *
                stepsPassed;
        }
        // If the starting price minus the decrement is greater than the resting price, return the decremented price
        if (
            _auctionInfo.startPrice >
            (_auctionInfo.restingPrice + priceDecrement)
        ) {
            return _auctionInfo.startPrice - priceDecrement;
            // If not, return the resting price
        } else {
            return _auctionInfo.restingPrice;
        }
    }

    /**
     * @dev Returns the current price (depending on the remaining supply) during the first minting phase (standard sale).
     */
    function _salePrice_gn2() private view returns (uint256) {
        uint256 curSupply = NFT.totalSupply();
        if (curSupply < 3333) return _SALE_PRICE1;
        else if (curSupply < 6666) return _SALE_PRICE2;
        else return _SALE_PRICE3;
    }

    /**
     * @dev Send proceeds to creator address and incentives to rewarder contract.
     */
    function _processWithdraw_SVt()
        private
        returns (bool creatorPaid, bool rewarderPaid)
    {
        uint256 balance = address(this).balance;
        uint256 incentives = balance / 10;
        uint256 creatorProceeds = balance - incentives;
        (rewarderPaid, ) = REWARDER_ADDRESS.call{value: incentives}("");
        (creatorPaid, ) = _creator.call{value: creatorProceeds}("");
    }
}

// Quack! :)