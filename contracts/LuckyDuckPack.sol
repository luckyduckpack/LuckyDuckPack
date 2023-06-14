// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";
import "operator-filter-registry/src/DefaultOperatorFilterer.sol";

/**
 * @title Lucky Duck Pack NFT contract
 *
 * @notice Commercial rights: As long as you own a Lucky Duck Pack NFT, you are
 * granted an unlimited, worldwide, non-exclusive, royalty-free license to
 * use, reproduce, and display the underlying artwork for commercial purposes,
 * including creating and selling derivative work such as merchandise
 * featuring the artwork.
 *
 * About the code: the LDP smart-contracts have been designed with the aim
 * of being efficient, secure, transparent and accessible. Even if you
 * don't have a programming background, take a look at the code for yourself.
 * Don't trust, verify.
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
 * deployment, meaning the creator has limited privileges and does not have the
 * power to fix, alter, or control its behavior.
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
contract LuckyDuckPack is
    Ownable,                            // Admin role
    ERC721("Lucky Duck Pack", "LDP"),   // NFT token standard
    ERC2981,                            // Royalty info standard
    DefaultOperatorFilterer,            // Prevent trades on marketplaces not honoring creator fees
    VRFConsumerBase                     // Chainlink Random (for collection reveal)
{
    using Strings for uint256;

    // =============================================================
    //                     CONTRACT VARIABLES
    // =============================================================

    // Supply cap
    uint256 public constant MAX_SUPPLY = 10000;
    // Keeps track of the total supply
    uint256 public totalSupply;
    // Final provenance hash - hardcoded for transparency
    string public constant PROVENANCE = "29c8c78a66ee0edd9d8825f9cc02fe8ed0b58f5e0c2bc8a89ae5be08f74ae077";
    // When the provenance record was stored in the smart-contract
    uint256 public immutable PROVENANCE_TIMESTAMP;
    // Deployer address
    address public immutable DEPLOYER;
    // Location where the collection information is stored
    string private _contract_URI;
    // Where the unrevealed token data is stored
    string private _unrevealed_URI;
    // Location prefix for token metadata (and images)
    string private _baseURI_IPFS; // IPFS
    string private _baseURI_AR; // Arweave
    /**
     * @notice To ensure long-term accessibility and reliability of the NFT
     * collection's off-chain data, we have implemented a redundant storage
     * solution using both IPFS and Arweave networks.
     * In the event of accessibility issues with IPFS, this variable can be
     * set to True, directing the contract to retrieve the off-chain data from
     * Arweave instead of IPFS.
     */
    bool public useArweaveUri;
    // Minter contract address
    address public minterContract;
    // Whether the reveal randomness has been already requested to Chainlink
    bool private _revealRequested;
    /**
     * @notice Once all tokens have been minted, a random offset number is
     * generated using VRF (Verifiable Random Function). This offset is then added
     * to the Token ID, and the resulting value is taken modulo of the maximum
     * supply of tokens to obtain the Revealed ID:
     *
     * [Revealed ID] = ([Token ID] + [Offset]) % [Max Supply]
     *
     * As the random offset is applied uniformly to all token IDs only after the
     * minting process is completed, the system cannot be exploited to cherry-pick
     * tokens with a higher rarity score. In other words, the distribution is
     * guaranteed to be fair and resistant to any potential hacks.
     */
    uint256 public revealOffset;
    /**
     * @notice Collection reveal timestamp.
     */
    uint256 public revealTimestamp;

    // Chainlink VRF (Verifiable Random Function) - fair collection reveal
    address private constant VRFcoordinator = 0xf0d54349aDdcf704F77AE15b96510dEA15cb7952; // Contract
    uint256 private constant fee = 2 * 10**18; // 2 LINK fee on Ethereum Mainnet
    bytes32 private constant keyHash = 0xAA77729D3466CA35AE8D28B3BBAC7CC36A5031EFDC430821C02BC31A238AF445;
    
    // Enumeration: Mapping from owner to list of owned token IDs
    mapping(address => mapping(uint256 => uint256)) private _ownedTokens;
    // Enumeration: Mapping from token ID to index of the owner tokens list
    mapping(uint256 => uint256) private _ownedTokensIndex;

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    /**
     * @dev Initialize the VRF module to work with Chainlink;
     * store the deployer's address; set the provenance timestamp.
     */
    constructor()
        VRFConsumerBase(
            VRFcoordinator, // Chainlink VRF Coordinator
            0x514910771AF9Ca656af840dff83E8264EcF986CA // LINK Token
        )
    {
        PROVENANCE_TIMESTAMP = block.timestamp;
        DEPLOYER = msg.sender;
    }

    // =============================================================
    //                      EVENTS AND ERRORS
    // =============================================================

    /**
     * @dev Emitted when the request for the random reveal offset is sent to the
     * Chainlink VRF Coordinator.
     */
    event RevealRequested(bytes32 indexed requestId);

    /**
     * @dev Emitted when the Chainlink VRF Coordinator fulfills the reveal request,
     * providing a random number to be used as the reveal offset.
     */
    event RevealFulfilled(
        bytes32 indexed requestId,
        uint256 indexed randomNumber
    );

    /**
     * @dev Custom error thrown when the mint function is called by an address
     * other than the minter contract.
     */
    error CallerIsNoMinter();

    /**
     * @dev Custom error thrown when one or more function parameters are empty/zero.
     * The 'index' parameter indicates the position of the empty input.
     */
    error EmptyInput(uint256 index);

    /**
     * @dev Custom error thrown when an attempt to mint tokens exceeds the
     * maximum allowed supply. The 'excess' parameter indicates the number of
     * tokens exceeding the max supply.
     */
    error MaxSupplyExceeded(uint256 excess);

    // =============================================================
    //                  CONTRACT INITIALIZATION
    // =============================================================

    /**
     * @notice Initializes the contract by setting the required parameters and
     * burning the admin keys to make the data effectively immutable.
     * This function is restricted to the contract owner and can only be called once.
     * @param minterAddress The address of the minter contract
     * @param rewarderAddress The address of the rewarder contract, which will receive
     * royalties
     * @param contract_URI The URI of the contract metadata
     * @param unrevealed_URI The URI to be returned for all tokens before reveal
     * @param baseURI_IPFS The base URI for the IPFS storage of token metadata
     * @dev The function reverts if the contract doesn't have sufficient LINK balance
     * for the collection reveal.
     */
    function initialize(
        address minterAddress,
        address rewarderAddress,
        string calldata contract_URI,
        string calldata unrevealed_URI,
        string calldata baseURI_IPFS
    ) external onlyOwner {
        // Validate input
        if(minterAddress==address(0)) revert EmptyInput(0);
        if(rewarderAddress==address(0)) revert EmptyInput(1);
        if(bytes(contract_URI).length==0) revert EmptyInput(2);
        if(bytes(unrevealed_URI).length==0) revert EmptyInput(3);
        if(bytes(baseURI_IPFS).length==0) revert EmptyInput(4);
        /// Ensure the contract has enough LINK tokens for the collection reveal
        require(LINK.balanceOf(address(this)) >= fee, "Not enough LINK for reveal");
        // Store the provided data
        minterContract = minterAddress;
        _contract_URI = contract_URI;
        _unrevealed_URI = unrevealed_URI;
        _baseURI_IPFS = baseURI_IPFS;
        // Set the default royalty for the rewarder address
        _setDefaultRoyalty(rewarderAddress, 800); // 800 basis points (8%)
        // Burn admin keys to make the data effectively immutable
        renounceOwnership();
    }

    // =============================================================
    //                          MINTING
    // =============================================================

    /**
     * @notice Mints tokens and assigns them to the specified account, callable only
     * by the minter contract.
     * @param account The address to which the minted tokens will be assigned
     * @param amount The number of tokens to be minted
     * @dev The minter contract ensures the minting amount is restricted to a maximum
     * of 10 tokens per call.
     * Throws a custom error if the caller is not the minter contract or if the total
     * supply would exceed the maximum allowed.
     */
    function mint_Qgo(address account, uint256 amount) external {
        if(_msgSender() != minterContract) revert CallerIsNoMinter();
        uint256 supplyBefore = totalSupply;
        uint256 supplyAfter;
        unchecked{ // Can be unchecked because the minter contract restricts amount to be <= 10
            supplyAfter = supplyBefore + amount;
        }
        if(supplyAfter > MAX_SUPPLY) revert MaxSupplyExceeded(supplyAfter - MAX_SUPPLY);
        totalSupply=supplyAfter;
        for(uint256 nextId = supplyBefore; nextId < supplyAfter;){
            _mint(account, nextId);
            unchecked{++nextId;}
        }
    }

    // =============================================================
    //                           REVEAL
    // =============================================================

    /**
     * @notice Initiates the collection reveal process by requesting randomness
     * from Chainlink VRF.
     * This function can be called by anyone, but only once and after all tokens
     * have been minted.
     * @return requestId The unique request ID associated with the Chainlink VRF
     * request
     * @dev Requires sufficient LINK balance to cover the VRF request fee
     */
    function reveal() external returns (bytes32 requestId) {
        require(totalSupply == MAX_SUPPLY, "Minting still in progress");
        require(!_revealRequested, "Reveal already requested");
        require(LINK.balanceOf(address(this)) >= fee, "Not enough LINK");
        _revealRequested = true; // Prevent being called more than once
        requestId = requestRandomness(keyHash, fee);
        emit RevealRequested(requestId);
    }

    /**
     * @notice Callback function used by Chainlink VRF to determine the reveal
     * offset for the collection.
     * This function can only be called by Chainlink.
     * @param requestId The unique request ID associated with the Chainlink VRF request
     * @param randomness The random value provided by Chainlink VRF
     * @dev This function ensures it is not called more than once and calculates
     * the reveal offset based on the received randomness.
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness)
        internal
        override
    {
        require(!_isRevealed(), "Already revealed"); // Ensure it's not called twice
        uint256 randomOffset = randomness % MAX_SUPPLY; // Compute the final value
        revealOffset = randomOffset == 0 ? 1 : randomOffset; // Ensure the offset is not zero
        revealTimestamp = block.timestamp; // Store the reveal timestamp
        emit RevealFulfilled(requestId, revealOffset);
    }

    /**
     * @notice Retrieves the revealed ID for a given token.
     * @param id The Token ID for which the revealed ID is requested.
     * @return The revealed ID as a uint256.
     */
    function revealedId(uint256 id) public view virtual returns (uint256) {
        require(_isRevealed(), "Collection not revealed");
        return (id + revealOffset) % MAX_SUPPLY;
    }

    // =============================================================
    //                            URI
    // =============================================================

    /**
     * @notice Change the location from which the offchain data is fetched
     * (IPFS / Arweave). If both locations are reachable, calling this has
     * basically no effect. This function is only useful if case the data
     * becomes unavailable/unreachable on one of the two networks.
     * For security reasons, only the contract deployer is allowed to use
     * this toggle.
     * Better safe than sorry.
     */
    function toggleArweaveUri() external {
        require(msg.sender == DEPLOYER, "Permission denied.");
        useArweaveUri = !useArweaveUri;
    }

    /**
     * @notice Sets the baseURI for the alternative off-chain data storage
     * location (Arweave).
     * If already set, the function reverts to prevent unauthorized modifications.
     * This function can only be called by the contract deployer for security
     * reasons.
     */
    function setArweaveBaseUri(string calldata baseURI_AR) external {
        require(msg.sender == DEPLOYER, "Permission denied.");
        require(bytes(_baseURI_AR).length==0, "Override denied.");
        _baseURI_AR = baseURI_AR;
    }

    /**
     * @notice Retrieves the URI containing the contract's metadata.*
     * @return The contract metadata URI as a string.
     */
    function contractURI() public view returns (string memory) {
        return _contract_URI;
    }

    /**
     * @notice Retrieves the URI associated with a specific token.
     * @param id The Token ID for which the URI is requested.
     * @return The token URI as a string.
     */
    function tokenURI(uint256 id) public view override returns (string memory) {
        require(_exists(id), "URI query for nonexistent token"); // Ensure that the token exists.
        return
            _isRevealed() // If revealed,
                ? string(abi.encodePacked(_actualBaseURI(), revealedId(id).toString())) // return baseURI+revealedId,
                : _unrevealed_URI; // otherwise return the unrevealedURI.
    }

    // =============================================================
    //                     INTERNAL FUNCTIONS
    // =============================================================

    /**
     * @dev Return True if the collection is revealed.
     */
    function _isRevealed() private view returns (bool) {
        return revealOffset != 0;
    }

    /**
     * @dev Return either Arweave or IPFS baseURI depending on the
     * value of "useArweaveUri".
     */
    function _actualBaseURI() private view returns (string memory) {
        return useArweaveUri ? _baseURI_AR : _baseURI_IPFS;
    }

    // =============================================================
    //                 TOKEN OWNERSHIP ENUMERATION
    // =============================================================

    // This section contains functions that help retrieving all tokens owned by the
    // same address, used by the Rewarder contract to cash out the revenues from all
    // the owned tokens at once.

    /**
     * @dev Returns a token ID owned by `owner` at a given `index` of its token list.
     */
    function tokenOfOwnerByIndex(address owner, uint256 index)
        external
        view
        returns (uint256)
    {
        require(index < ERC721.balanceOf(owner), "Index out of bounds");
        return _ownedTokens[owner][index];
    }

    /**
     * @dev Adds owner enumeration to token transfers.
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId);
        if (from != to) {
            if (from != address(0)) {
                _removeFromEnumeration_bIF(from, tokenId);
            }
            _addToEnumeration_j9B(to, tokenId);
        }
    }

    /**
     * @dev Add a token to ownership-tracking data structures.
     * @param to address representing the new owner of the given token ID
     * @param tokenId uint256 ID of the token to be added to the tokens list of the given address
     */
    function _addToEnumeration_j9B(address to, uint256 tokenId) private {
        uint256 length = ERC721.balanceOf(to);
        _ownedTokens[to][length] = tokenId;
        _ownedTokensIndex[tokenId] = length;
    }

    /**
     * @dev Remove a token from ownership-tracking data structures. Note that
     * @param from address representing the previous owner of the given token ID
     * @param tokenId uint256 ID of the token to be removed from the tokens list of the given address
     */
    function _removeFromEnumeration_bIF(address from, uint256 tokenId) private {
        uint256 lastTokenIndex = ERC721.balanceOf(from) - 1;
        uint256 tokenIndex = _ownedTokensIndex[tokenId];
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = _ownedTokens[from][lastTokenIndex];
            _ownedTokens[from][tokenIndex] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = tokenIndex;
        }
        delete _ownedTokensIndex[tokenId];
        delete _ownedTokens[from][lastTokenIndex];
    }

    // =============================================================
    //                   CREATOR FEES ENFORCEMENT
    // =============================================================

    // This section implements the Operator Filterer developed by Opensea (prevent
    // token sales on marketplaces that don't honor creator fees).
    
    /**
     * @dev Adds {OperatorFilterer-onlyAllowedOperatorApproval} modifier.
     */
    function setApprovalForAll(address operator, bool approved)
        public
        override
        onlyAllowedOperatorApproval(operator)
    {
        super.setApprovalForAll(operator, approved);
    }

    /**
     * @dev Adds {OperatorFilterer-onlyAllowedOperatorApproval} modifier.
     */
    function approve(address operator, uint256 tokenId)
        public
        override
        onlyAllowedOperatorApproval(operator)
    {
        super.approve(operator, tokenId);
    }

    /**
     * @dev Adds {OperatorFilterer-onlyAllowedOperator} modifier.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override onlyAllowedOperator(from) {
        super.transferFrom(from, to, tokenId);
    }

    /**
     * @dev Adds {OperatorFilterer-onlyAllowedOperator} modifier.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, tokenId);
    }

    /**
     * @dev Adds {OperatorFilterer-onlyAllowedOperator} modifier.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public override onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    // =============================================================
    //            ERC2981 (CREATOR FEES) IMPLEMENTATION
    // =============================================================

    /**
     * @dev Override required for ERC2981 support
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, ERC2981)
        returns (bool)
    {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }

}

// Quack! :)