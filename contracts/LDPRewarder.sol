// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./lib/interfaces/ILDP.sol";
import "./lib/tools/WethUnwrapper.sol";

/**
 * @title Lucky Duck Pack Rewarder
 * 
 * @notice This contract receives 100% of the creator fees from LDP trades.
 * Whenever funds are received, a portion is set aside for each LDP token;
 * token owners can claim their portion at any moment by calling {cashout}.
 *
 * The contract reserves 6.25% of the received funds for the collection
 * creator, with the remaining 93.75% going to token holders proportionally
 * to the number of tokens they own.
 *
 * No staking, nor other actions, are required: hold your token(s), claim
 * your rewards - it's THAT simple.
 *
 * Important: The rewards are tied to the tokens, not to the holder addresses,
 * meaning that if an NFT is sold or transferred without claiming its rewards
 * first, the new owner will have the right to do so.
 *
 * Supported currencies are ETH and WETH by default. In the event that creator fees
 * are received in other currencies, a separate set of functions to manually
 * process/cashout any ERC20 token is provided.
 *
 * This contract is fair, unstoppable, unpausable, immutable: there is no admin
 * role, while the Creator has only the authority to change their cashout address
 * but has no access to the funds reserved to the NFT holders.
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
 * The Software is inherently unalterable after deployment. It has been designed
 * without admin keys or any other form of privileged control, which means it
 * cannot be modified, controlled, or manipulated after its deployment.
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
contract LDPRewarder is ReentrancyGuard {

    // =============================================================
    //                        CUSTOM TYPES
    // =============================================================

    /**
     * @dev Type defining rewards info.
     * Keeps track of lifetime rewards and lifetime cashout of each NFT, so that:
     * [newRewards] = [lifetimeAccrued] - [lifetimeCollected]
     */
    struct Rewards {
        uint256 lifetimeAccrued; // Lifetime accrued rewards of each NFT
        mapping(uint256 => uint256) lifetimeCollected; // NFT ID => amount
        // Creator Lifetime Accrued == lifetimeAccrued*10000/15
        // Creator Lifetime Collected == lifetimeCollected[_creatorId]
    }

    // =============================================================
    //                     CONTRACT VARIABLES
    // =============================================================

    // ETH rewards data
    Rewards private _rewards;
    // ERC20 tokens rewards data
    mapping(address => Rewards) private _erc20Rewards; // Token address => Rewards
    // Track the processed ERC20 rewards to identify funds received since last records update
    mapping(address => uint256) private _processedErc20Rewards; // Token address => balance

    // Creator address - only for cashout: creator has no special permissions
    address private _creator;
    // Used to transfer the creator status to a new address
    address private _creatorCandidate;
    // ID representing the creator within the mapping "lifetimeCollected"
    uint256 private constant _CREATOR_ID = 31415926535;
    // Lucky Duck Pack NFT contract
    ILDP public immutable NFT;
    // WETH token address and WETH Unwrapper contract
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    WethUnwrapper private immutable wethUnwrapper;

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    /**
     * @dev Initializes the contract by setting the creator address, storing the
     * NFT contract address, and initializing the WETH unwrapper contract.
     * @param nftAddress The address of the LuckyDuckPack NFT contract
     * @param creatorAddress The address of the creator
     */
    constructor(address nftAddress, address creatorAddress) {
        _creator = creatorAddress;
        NFT = ILDP(nftAddress);
        wethUnwrapper = new WethUnwrapper(WETH);
    }

    // =============================================================
    //                      EVENTS AND ERRORS
    // =============================================================

    /**
     * @dev Emitted when the contract receives ETH.
     */
    event ReceivedEth(uint256 indexed amount);
    /**
     * @dev Emitted when the unprocessed WETH is unwrapped.
     */
    event UnwrappedWeth();
    /**
     * @dev Emitted when ERC20 records are updated.
     */
    event ProcessedErc20(address indexed tokenAddress, uint256 indexed amount);
    /**
     * @dev Emitted when ETH is withdrawn.
     */
    event Cashout(address indexed account, uint256 indexed amount);
    /**
     * @dev Emitted when an ERC20-token is withdrawn.
     */
    event CashoutErc20(
        address indexed account,
        uint256 indexed amount,
        address indexed token
    );
    /**
     * @dev Raised on payout errors.
     */
    error CashoutError();
    /**
     * @dev Returned when sender doesn't own the NFT being processed.
     */
    error SenderIsNoTokenOwner(uint256 tokenId);
    /**
     * @dev Returned by {noWeth} modifier when ERC20-reserved operations
     * are attempted on WETH; check {noWeth} documentation for more info.
     */
    error NotAllowedOnWETH();

    // =============================================================
    //                          MODIFIERS
    // =============================================================

    /**
     * @dev Rewards in Wrapped Ether (WETH) are meant to be converted to ETH
     * (rather than claimed separately like any other ERC20): this modifier
     * prevents ERC20 functions from operating with WETH.
     */
    modifier noWeth(address tokenContract) {
        if (tokenContract == WETH) revert NotAllowedOnWETH();
        _;
    }

    /**
     * @dev Ensures that the function using this modifier can only be executed
     * by the owner of the NFT with the specified `tokenId`.
     */
    modifier onlyTokenOwner(uint256 tokenId) {
        if (msg.sender != NFT.ownerOf(tokenId))
            revert SenderIsNoTokenOwner(tokenId);
        _;
    }

    // =============================================================
    //                       RECEIVE FUNCTION
    // =============================================================

    /**
     * @dev Update the revenue records when ETH are received.
     */
    receive() external payable {
        _updateRevenueRecords_tku(msg.value);
        emit ReceivedEth(msg.value);
    }

    // =============================================================
    //                       USER FUNCTIONS
    // =============================================================

    /**
     * @notice Cashout the rewards (eth) accrued by all owned NFTs.
     */
    function cashout() external nonReentrant {
        _accountCashout_dHm(msg.sender);
    }

    /**
     * @notice Cashout rewards (eth) accrued by the specified NFT.
     * @param tokenId The ID of the Duck for which the ETH rewards will be cashed out
     */
    function nftCashout(uint256 tokenId) external nonReentrant {
        _nftCashout_M29(tokenId);
    }

    /**
     * @notice Similar to {cashout} but works with any ERC20 token.
     * @param tokenAddress The address of the ERC20 token contract for which
     * the rewards will be cashed out
     */
    function cashoutErc20(address tokenAddress)
        external
        nonReentrant
        noWeth(tokenAddress)
    {
        // Update the ERC20-token records for the specified token contract
        _updateErc20Revenues_a8w(tokenAddress);
        // Cash out the ERC20-token rewards for the calling account
        _accountCashout_h8W(msg.sender, tokenAddress);
    }

    /**
     * @notice Same as {nftCashout}, but working with any ERC20 token.
     * @param tokenId The ID of the Duck for which the ERC20-token rewards will be cashed out
     * @param tokenAddress The address of the ERC20 token contract
     */
    function nftCashoutErc20(uint256 tokenId, address tokenAddress)
        external
        nonReentrant
        noWeth(tokenAddress)
    {
        _nftCashout_0G0(tokenId, tokenAddress);
    }

    /**
     * @notice Cashout the creator rewards.
     */
    function creatorCashout() external nonReentrant {
        _creatorCashout_89e();
    }

    /**
     * @notice Similar to {creatorCashout} but works with any ERC20 token.
     * @param tokenAddress Address of the ERC20 token contract.
     */
    function creatorCashoutErc20(address tokenAddress)
        external
        nonReentrant
        noWeth(tokenAddress)
    {
        _creatorCashout_gl3(tokenAddress);
    }

    /**
     * @notice Unwraps all the WETH held by the contract.
     */
    function unwrapWeth() external {
        _unwrapWethIfAny__um();
    }

    /**
     * @notice Force updating the records of the given ERC20 token (unlike
     * ETH records, which are updated automatically, ERC20 records require
     * a manual update).
     * @param tokenAddress Address of the ERC20 token contract
     */
    function forceUpdateErc20Records(address tokenAddress)
        external
        noWeth(tokenAddress)
    {
        _updateErc20Revenues_a8w(tokenAddress);
    }

    /**
     * @notice Check if the contract has any WETH pending to be unwrapped.
     */
    function unprocessedWeth() external view returns (uint256) {
        return IWETH(WETH).balanceOf(address(this));
    }

    /**
     * @notice Returns the total unclaimed rewards accrued by tokens held
     * by `account`.
     * @param account The address of the account for which the unclaimed
     * rewards will be calculated
     * @return accruedRewards The total unclaimed rewards of the tokens
     * held by the specified account
     */
    function accountRevenues(address account)
        external
        view
        returns (uint256 accruedRewards)
    {
        // Get the number of tokens owned by the specified account
        uint256 numOwned = NFT.balanceOf(account);
        // Iterate through all the tokens owned by the account
        for (uint256 i; i < numOwned; ) {
            // Accumulate the rewards of each token owned by the account
            accruedRewards += _getNftRevenues_idw(
                _rewards,
                NFT.tokenOfOwnerByIndex(account, i)
            );
            // Increment the index (no need to check for overflow)
            unchecked {++i;}
        }
    }

    /**
     * @notice ERC20-token version of {accountRevenues}. The function
     * {isErc20RecordsUpToDate} can be used to check if these records
     * are already up to date; if not, these can be updated by calling
     * {forceUpdateErc20Records}.
     * @param account The address of the account for which the unclaimed
     * ERC20-token rewards will be calculated
     * @param tokenAddress tokenAddress The address of the ERC20 token contract
     * @return accruedRewards The total unclaimed rewards (in the given
     * ERC20-token) of the tokens held by the specified account
     */
    function accountRevenuesErc20(address account, address tokenAddress)
        external
        view
        returns (uint256 accruedRewards)
    {
        // If the tokenAddress is WETH, always return 0 (there is a separate set of functions for WETH)
        if (tokenAddress == WETH) return 0;
        else {
            // Get the number of tokens owned by the specified account
            uint256 numOwned = NFT.balanceOf(account);
            // Iterate through all the tokens owned by the account
            for (uint256 i; i < numOwned; ) {
                // Accumulate the ERC20-token rewards of each token owned by the account
                accruedRewards += _getNftRevenues_idw(
                    _erc20Rewards[tokenAddress],
                    NFT.tokenOfOwnerByIndex(account, i)
                );
                // Increment the index (no need to check for overflow)
                unchecked {++i;}
            }
        }
    }

    /**
     * @notice Returns the unclaimed rewards accrued by the token `tokenId`.
     */
    function nftRevenues(uint256 tokenId) external view returns (uint256) {
        return _getNftRevenues_idw(_rewards, tokenId);
    }

    /**
     * @notice ERC20-token version of {nftRevenues}.
     * @param tokenId Id of the LDP nft
     * @param tokenAddress Address of the ERC20 token contract
     * @return The total unclaimed rewards of the specified NFT in the given
     * ERC20-token
     */
    function nftRevenuesErc20(uint256 tokenId, address tokenAddress)
        external
        view
        returns (uint256)
    {
        // If the tokenAddress is WETH, always return 0 (there is a separate set of functions for WETH)
        if (tokenAddress == WETH) return 0;
        // Otherwise return the ERC20-token rewards of the specified NFT
        else return _getNftRevenues_idw(_erc20Rewards[tokenAddress], tokenId);
    }

    /**
     * @notice Returns true if the records of the provided ERC20 token are
     * up to date.
     * @param tokenAddress Address of the ERC20 token contract.
     */
    function isErc20RecordsUpToDate(address tokenAddress)
        external
        view
        returns (bool)
    {
        if (tokenAddress == WETH) return true;
        else
            return
                IERC20(tokenAddress).balanceOf(address(this)) ==
                _processedErc20Rewards[tokenAddress];
    }

    /**
     * @notice Return the lifetime rewards distributed to NFT holders (ETH).
     * @return The total lifetime rewards of the NFT holders
     */
    function collectionEarningsLifetime() external view returns (uint256) {
        return _rewards.lifetimeAccrued * 10000;
    }

    /**
     * @notice Return the lifetime rewards distributed to NFT holders (ERC20).
     * @param tokenContract The address of the ERC20 token contract
     * @return The total lifetime rewards (in the given ERC20 token) of the NFT
     * holders
     */
    function collectionEarningsLifetime(address tokenContract)
        external
        view
        returns (uint256)
    {
        return _erc20Rewards[tokenContract].lifetimeAccrued * 10000;
    }

    // =============================================================
    //                     CREATOR TRANSFER
    // =============================================================

    /**
     * @notice Function that can be used by the Creator to change their
     * address. In order to complete the change, the target address
     * must then call {creatorTransferFulfill}.
     * It is also possible to cancel a previous request by calling this
     * function with address(0) as parameter.
     */
    function creatorTransferRequest(address newAddress) external {
        require(msg.sender == _creator, "Caller is not creator.");
        _creatorCandidate = newAddress;
    }

    /**
     * @notice Function to complete the Creator address change.
     * Check {creatorTransferRequest} for more info.
     */
    function creatorTransferFulfill() external {
        require(msg.sender == _creatorCandidate, "Caller is not creator candidate.");
        _creatorCandidate = address(0);
        _creator = msg.sender;
    }

    // =============================================================
    //                      INTERNAL LOGICS
    // =============================================================

    /**
     * @dev Unwrap any WETH held by this smart contract.
     * When WETH is unwrapped, the receive function is called, which adds
     * the resulting ETH to the revenue records. This is a workaround to
     * enable automatic revenue distribution for creator fees received in WETH.
     */
    function _unwrapWethIfAny__um() private {
        uint256 bal = IWETH(WETH).balanceOf(address(this));
        if (bal != 0) {
            bool success = IWETH(WETH).transfer(address(wethUnwrapper), bal);
            if(success){
                wethUnwrapper.unwrap_aof(bal);
                wethUnwrapper.withdraw_wdp();
                emit UnwrappedWeth();
            }
        }
    }

    /**
     * @dev Send to `account` all ETH rewards accrued by its tokens.
     * @param account Account address
     */
    function _accountCashout_dHm(address account) private {
        uint256 amount;
        uint256 numOwned = NFT.balanceOf(account);
        for (uint256 i; i < numOwned; ) {
            unchecked {
                amount += _processWithdrawData_Il8(
                    _rewards,
                    NFT.tokenOfOwnerByIndex(account, i)
                );
                ++i;
            }
        }
        _cashout_qLL({recipient: account, amount: amount});
    }

    /**
     * @dev ERC20-token version of {_accountCashout_dHm}.
     * @param account Account address
     * @param tokenAddress Address of the ERC20 token contract
     */
    function _accountCashout_h8W(address account, address tokenAddress)
        private
    {
        uint256 amount;
        uint256 numOwned = NFT.balanceOf(account);
        for (uint256 i; i < numOwned; ) {
            unchecked {
                amount += _processWithdrawData_Il8(
                    _erc20Rewards[tokenAddress],
                    NFT.tokenOfOwnerByIndex(account, i)
                );
                ++i;
            }
        }
        _cashout_KTv({token: tokenAddress, recipient: account, amount: amount});
    }

    /**
     * @dev Send all ETH rewards accrued by the token `tokenId` to its
     * current owner.
     */
    function _nftCashout_M29(uint256 tokenId)
        private
        onlyTokenOwner(tokenId)
    {
        uint256 amount = _processWithdrawData_Il8(_rewards, tokenId);
        _cashout_qLL({recipient: msg.sender, amount: amount});
    }

    /**
     * @dev ERC20-token version of {_nftCashout_M29}.
     * @param tokenId Id of the token to be used for cashout
     * @param tokenAddress Address of the ERC20 token contract
     */
    function _nftCashout_0G0(uint256 tokenId, address tokenAddress)
        private
        onlyTokenOwner(tokenId)
    {
        uint256 amount = _processWithdrawData_Il8(
            _erc20Rewards[tokenAddress],
            tokenId
        );
        _cashout_KTv({
            token: tokenAddress,
            recipient: msg.sender,
            amount: amount
        });
    }

    /**
     * @dev Send creator revenues to their address.
     */
    function _creatorCashout_89e() private {
        uint256 earnings = _processWithdrawDataCreator_sFU(_rewards);
        _cashout_qLL({recipient: _creator, amount: earnings});
    }

    /**
     * @dev ERC20-token version of {_creatorCashout_89e}.
     * @param tokenAddress Address of the ERC20 token contract.
     */
    function _creatorCashout_gl3(address tokenAddress) private {
        uint256 earnings = _processWithdrawDataCreator_sFU(
            _erc20Rewards[tokenAddress]
        );
        _cashout_KTv({
            token: tokenAddress,
            recipient: _creator,
            amount: earnings
        });
    }

    /**
     * @dev Updates the ETH revenue records when new ETH is received.
     * This function is called automatically when ETH is received by the
     * smart contract.
     * @param newRevenues Amount of ETH to be added to the revenue records
     */
    function _updateRevenueRecords_tku(uint256 newRevenues) private {
        uint256 holdersCut = _calculateHolderRevenues_x8f(newRevenues);
        unchecked {
            _rewards.lifetimeAccrued += (holdersCut / 10000);
        }
    }

    /**
     * @dev Same as {_updateRevenueRecords_tku} but for ERC20 tokens.
     * @param newRevenues Amount to be added to rewards
     * @param tokenAddress Address of the ERC20 token contract
     * @param tokenBalance Up-to-date token balance of this contract
     */
    function _updateRevenueRecords_e20(
        uint256 newRevenues,
        address tokenAddress,
        uint256 tokenBalance
    ) private {
        uint256 holdersCut = _calculateHolderRevenues_x8f(newRevenues);
        unchecked {
            _erc20Rewards[tokenAddress].lifetimeAccrued += (holdersCut /
                10000);
        }
        _processedErc20Rewards[tokenAddress] = tokenBalance;
    }

    /**
     * @dev Calls {_updateRevenueRecords_e20} to update the token revenue
     * records, but only if the records of the specified ERC20 token are
     * not up to date.
     * Note: this cannot be called automatically when receiving ERC20 token
     * transfers. As a workaround, it is called by {cashoutErc20} before
     * performing the actual withdraw.
     * @param tokenAddress Address of the ERC20 token contract
     */
    function _updateErc20Revenues_a8w(address tokenAddress) private {
        uint256 curBalance = IERC20(tokenAddress).balanceOf(address(this));
        uint256 processedRevenues = _processedErc20Rewards[tokenAddress];
        if (curBalance > processedRevenues) {
            uint256 _newRevenues;
            unchecked {
                _newRevenues = curBalance - processedRevenues;
            }
            _updateRevenueRecords_e20(
                _newRevenues,
                tokenAddress,
                curBalance
            );
            emit ProcessedErc20(tokenAddress, _newRevenues);
        }
    }

    /**
     * @dev Called when rewards are claimed: returns the amount of rewards
     * claimable by the specified token ID and records that these rewards
     * have now been collected.
     * @param tokenId Id of the LDP token
     */
    function _processWithdrawData_Il8(
        Rewards storage revenueRecords,
        uint256 tokenId
    ) private returns (uint256 accruedRevenues) {
        uint256 lifetimeAccrued = revenueRecords.lifetimeAccrued;
        unchecked {
            accruedRevenues =
                lifetimeAccrued -
                revenueRecords.lifetimeCollected[tokenId];
        }
        revenueRecords.lifetimeCollected[tokenId] = lifetimeAccrued;
    }

    /**
     * @dev Same as {_processWithdrawData_Il8} but working on creator revenues:
     * returns the amount of revenues claimable by the collection creator
     * and records that these revenues have now been collected.
     */
    function _processWithdrawDataCreator_sFU(
        Rewards storage revenueRecords
    ) private returns (uint256 accruedRevenues) {
        unchecked {
            uint256 lifetimeEarningsCr = (revenueRecords.lifetimeAccrued *
                10000) / 15;
            accruedRevenues =
                lifetimeEarningsCr -
                revenueRecords.lifetimeCollected[_CREATOR_ID];
            revenueRecords.lifetimeCollected[_CREATOR_ID] = lifetimeEarningsCr;
        }
    }

    /**
     * @dev Returns the unclaimed rewards accrued by the given tokenId.
     */
    function _getNftRevenues_idw(
        Rewards storage revenueRecords,
        uint256 tokenId
    ) private view returns (uint256) {
        unchecked {
            return
                revenueRecords.lifetimeAccrued -
                revenueRecords.lifetimeCollected[tokenId];
        }
    }

    /**
     * @dev Calculate holder rewards from the given amount.
     * 93.75% to holders, 6.25% to creator
     */
    function _calculateHolderRevenues_x8f(
        uint256 amount
    ) private pure returns (uint256 holderRevenues) {
        unchecked {
            holderRevenues = (amount * 15) / 16; // 15/16 == 93.75%
        }
    }

    /**
     * @dev Private function used by cashout functions to transfer funds.
     * @param recipient Destination to send funds to
     * @param amount Amount to be sent
     */
    function _cashout_qLL(address recipient, uint256 amount) private {
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert CashoutError();
        emit Cashout(recipient, amount);
    }

    /**
     * @dev ERC20-token version of {_cashout_qLL}.
     * @param token ERC20 token address
     * @param recipient Destination to send funds to
     * @param amount Amount to be sent
     */
    function _cashout_KTv(
        address token,
        address recipient,
        uint256 amount
    ) private {
        unchecked {
            _processedErc20Rewards[token] -= amount;
        }
        bool success = IERC20(token).transfer(recipient, amount);
        if (!success) revert CashoutError();
        emit CashoutErc20(recipient, amount, token);
    }
}

// Quack! :)