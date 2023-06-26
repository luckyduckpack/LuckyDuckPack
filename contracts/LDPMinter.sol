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
 *
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
 * constitute legal advice. The laws and regulations applicable to smart contracts
 * and blockchain technologies vary by jurisdiction. As such, you are strongly
 * advised to consult with your legal counsel before engaging in any smart
 * contract or blockchain-related activities.
 *
 * The creator of the Software disclaims all responsibility and liability for the
 * accuracy, applicability, or completeness of the Software. Any use or reliance
 * on the Software or any part thereof is strictly at your own risk, and you fully
 * accept and assume all risks associated with any such reliance. This includes,
 * but is not limited to, responsibility for the consequences of any errors,
 * inaccuracies, omissions, or other defects that may be present in the Software.
 *
 * You agree to indemnify and hold harmless the creator of the Software from and
 * against any and all losses, liabilities, claims, damages, costs, and expenses,
 * including legal fees and disbursements, arising out of or resulting from your
 * use of the Software.
 * 
 * By using the Software, you acknowledge that you have read and understood this
 * disclaimer, and agree to be bound by its terms.
 * --------------------------------------------------------------------------
 */
contract LDPMinter is Ownable, ReentrancyGuard {

    // =============================================================
    //                     CONTRACT VARIABLES
    // =============================================================

    // Pricing - hard-coded for transparency and efficiency - NOTE: Current prices are placeholders!
    uint256 private constant _PRICE1 = 0.5 ether; // Price for tokens 1 to 3333
    uint256 private constant _PRICE2 = 0.8 ether; // Price for tokens 3334 to 6666
    uint256 private constant _PRICE3 = 1.3 ether; // Price for tokens 6667 to 10000
    // Number of tokens reserved for the team
    uint256 private constant _TEAM_RESERVED = 35;
    // Instance of the token contract
    ILDP public immutable NFT;
    // LDP Rewarder contract address
    address public immutable REWARDER_ADDRESS;
    // Collection creator address
    address private _creator;
    // Total supply at last proceeds withdrawal - tracks incentives already sent
    uint256 private _supplyAtLastWithdraw;
    // If set to 'true' by admin, minting is enabled and cannot be disabled
    bool public mintingStarted;

    // =============================================================
    //                  CUSTOM ERRORS AND EVENTS
    // =============================================================

    event MintingStarted(); // Emitted when the minting is opended

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
    ){
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
        if (!mintingStarted) revert MintingNotStarted();
        // Revert if attempting to mint more than 10 tokens at once
        if (amount > 10) revert MaxMintsPerCallExceeded();
        // Revert if underpaying
        unchecked {
            if (msg.value < _currentPrice_t6y() * amount)
                revert Underpaid(msg.value, _currentPrice_t6y() * amount);
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
        if (mintingStarted) revert MintingAlreadyStarted();
        mintingStarted = true;
        _supplyAtLastWithdraw = _TEAM_RESERVED; // These aren't paid
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
     * @notice Get the current price.
     */
    function currentPrice() external view returns (uint256) {
        return _currentPrice_t6y();
    }

    // =============================================================
    //                    FUNCTIONS - CASH OUT
    // =============================================================

    /**
     * @notice Set the creator address.
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
        if (!mintingStarted) revert MintingNotStarted();
        if (_msgSender() != owner())
            require(_msgSender() == _creator, "Caller is not admin nor creator");
        uint256 currentSupply = NFT.totalSupply();
        uint256 newSales = currentSupply - _supplyAtLastWithdraw;
        _supplyAtLastWithdraw = currentSupply; // Storage variable update
        // Actual withdraw
        (bool creatorPaid, bool rewarderPaid) = _processWithdraw_ama(newSales);
        // Revert if one or both payments failed
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
        uint256 currentSupply = NFT.totalSupply();
        require(currentSupply == NFT.MAX_SUPPLY(), "Minting still in progress");
        // Attempt the normal withdraw first: if succeeds, emergency actions won't be performed
        uint256 newSales = currentSupply - _supplyAtLastWithdraw;
        _supplyAtLastWithdraw = currentSupply;
        (bool creatorPaid, bool rewarderPaid) = _processWithdraw_ama(newSales);
        // If one of the two payments failed, send the remaining balance to admin
        if (!(creatorPaid && rewarderPaid)) {
            uint256 _bal = address(this).balance;
            payable(_msgSender()).transfer(_bal);
        }
    }

    // =============================================================
    //                       PRIVATE FUNCTIONS
    // =============================================================

    /**
     * @dev Returns the current price (depending on the remaining supply).
     */
    function _currentPrice_t6y() private view returns (uint256) {
        uint256 curSupply = NFT.totalSupply();
        if (curSupply < 3333) return _PRICE1;
        else if (curSupply < 6666) return _PRICE2;
        else return _PRICE3;
    }

    /**
     * @dev Send proceeds to creator address and incentives to rewarder contract.
     * @param newTokensSold Number of new sales
     */
    function _processWithdraw_ama(
        uint256 newTokensSold
    ) private returns (bool creatorPaid, bool rewarderPaid) {
        uint256 incentivesPerSale = 0.05 ether; // Note: Placeholder value. Ideally, ~10-15% of the average sale price.
        uint256 totalIncentives = incentivesPerSale * newTokensSold;
        uint256 _bal = address(this).balance;
        if (totalIncentives < _bal) {
            uint256 creatorProceeds = _bal - totalIncentives;
            (rewarderPaid, ) = REWARDER_ADDRESS.call{value: totalIncentives}("");
            (creatorPaid, ) = _creator.call{value: creatorProceeds}("");
        }
    }
}

// Quack! :)