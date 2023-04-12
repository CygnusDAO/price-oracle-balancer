// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.4;

// Dependencies
import {ICygnusNebulaOracle} from "./interfaces/ICygnusNebulaOracle.sol";
import {Context} from "./utils/Context.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {ERC20Normalizer} from "./utils/ERC20Normalizer.sol";

// Libraries
import {PRBMath, PRBMathUD60x18} from "./libraries/PRBMathUD60x18.sol";
import {PRBMathSD59x18} from "./libraries/PRBMathSD59x18.sol";

// Interfaces
import {IERC20} from "./interfaces/IERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IWeightedPool} from "./interfaces/IWeightedPool.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/**
 *  @title  CygnusNebulaOracle
 *  @author CygnusDAO
 *  @notice Oracle used by Cygnus that returns the price of 1 BPT in the denomination token. In case need
 *          different implementation just update the denomination variable `denominationAggregator`
 *          and `denominationToken` with token.
 *  @notice modified from Revest Finance 
 *          https://revestfinance.medium.com/dev-blog-on-the-derivation-of-a-safe-price-formula-for-balancer-pool-tokens-33e8993455d0
 */
contract CygnusNebulaOracle is ICygnusNebulaOracle, Context, ReentrancyGuard, ERC20Normalizer {
    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            1. LIBRARIES
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @custom:library PRBMathUD60x18 Smart contract library for advanced fixed-point math that works with uint256
     */
    using PRBMathUD60x18 for uint256;

    /**
     *  @custom:library PRBMathSD59x18 Smart contract library for advanced fixed-point math that works with int256
     */
    using PRBMathSD59x18 for int256;

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            2. STORAGE
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Internal ───────────────────────────────────────────────  */

    /**
     *  @notice Internal record of all initialized oracles
     */
    mapping(address => CygnusNebula) internal nebulas;

    /*  ─────────────────────────────────────────────── Public ────────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    address[] public override allNebulas;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    string public constant override name = "Cygnus-Nebula: Weighted LP Oracle";

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    string public constant override symbol = "CygNebula";

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    string public constant override version = "1.0.0";

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    uint256 public constant override SECONDS_PER_YEAR = 31536000;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    IERC20 public immutable override denominationToken;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    uint8 public immutable override decimals;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    AggregatorV3Interface public immutable override denominationAggregator;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    address public override admin;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    address public override pendingAdmin;

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    IVault public constant override VAULT = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            3. CONSTRUCTOR
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @notice Constructs the Oracle
     *  @param denomination The denomination token, used to get the decimals that this oracle retursn the price in.
     *         ie If denomination token is USDC, the oracle will return the price in 6 decimals, if denomination
     *         token is DAI, the oracle will return the price in 18 decimals.
     *  @param denominationPrice The denomination token this oracle returns the prices in
     */
    constructor(IERC20 denomination, AggregatorV3Interface denominationPrice) {
        // Assign admin
        admin = _msgSender();

        // Denomination token
        denominationToken = denomination;

        // Decimals for the oracle based on the denomination token
        decimals = denomination.decimals();

        // Assign the denomination the LP Token will be priced in
        denominationAggregator = AggregatorV3Interface(denominationPrice);

        // Cache scalar of denom token price
        computeScalar(IERC20(address(denominationPrice)));
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            4. MODIFIERS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @custom:modifier cygnusAdmin Modifier for admin control only 👽
     */
    modifier cygnusAdmin() {
        isCygnusAdmin();
        _;
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            5. CONSTANT FUNCTIONS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Internal ───────────────────────────────────────────────  */

    /**
     *  @notice Internal check for admin control only 👽
     */
    function isCygnusAdmin() internal view {
        /// @custom:error MsgSenderNotAdmin Avoid unless caller is Cygnus Admin
        if (_msgSender() != admin) {
            revert CygnusNebulaOracle__MsgSenderNotAdmin(_msgSender());
        }
    }

    /*  ─────────────────────────────────────────────── Public ────────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function getNebula(address lpTokenPair) public view override returns (CygnusNebula memory) {
        return nebulas[lpTokenPair];
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function nebulaSize() public view override returns (uint24) {
        // Return how many LP Tokens we are tracking
        return uint24(allNebulas.length);
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function getAnnualizedBaseRate(
        uint256 exchangeRateLast,
        uint256 exchangeRateCurrent,
        uint256 timeElapsed
    ) public pure override returns (uint256) {
        // Get the natural logarithm of last exchange rate
        uint256 logRateLast = exchangeRateLast.ln();

        // Get the natural logarithm of current exchange rate
        uint256 logRateCurrent = exchangeRateCurrent.ln();

        // Get the log rate difference between the exchange rates
        uint256 logRateDiff = logRateCurrent - logRateLast;

        // The log APR is = (lorRateDif * 1 year) / time since last update
        uint256 logAprInYear = (logRateDiff * SECONDS_PER_YEAR) / timeElapsed;

        // Get the natural exponent of the log APR and substract 1
        uint256 annualizedApr = logAprInYear.exp() - 1e18;

        // Returns the annualized APR, taking into account time since last update
        return annualizedApr;
    }

    /*  ────────────────────────────────────────────── External ───────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function denominationTokenPrice() external view override returns (uint256) {
        // Chainlink price feed for the LP denomination token
        (, int256 latestRoundUsd, , , ) = denominationAggregator.latestRoundData();

        // Return price without adjusting decimals - not used by this contract, we keep it here to quickly check
        // in case something goes wrong
        return uint256(latestRoundUsd);
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function lpTokenPriceUsd(address lpTokenPair) external view override returns (uint256 lpTokenPrice) {
        // Load to memory
        ICygnusNebulaOracle.CygnusNebula memory cygnusNebula = nebulas[lpTokenPair];

        /// custom:error PairNotInitialized Avoid getting price unless lpTokenPair's price is being tracked
        if (!cygnusNebula.initialized) {
            revert CygnusNebulaOracle__PairNotInitialized(lpTokenPair);
        }

        // 1. Get the fixed weights
        uint256[] memory weights = IWeightedPool(lpTokenPair).getNormalizedWeights();

        // 2. Loop through each prices and update `totalPi`
        int256 totalPi = PRBMathSD59x18.fromInt(1e18);

        // Pool tokens length
        for (uint256 i = 0; i < cygnusNebula.poolTokens.length; i++) {
            // Get price from Chainlink for token `i` from the LP (order of oracle tokens must be same as weight tokens)
            (, int256 price, , , ) = cygnusNebula.priceFeeds[i].latestRoundData();

            // Normalize price
            uint256 adjustedPrice = normalize(IERC20(address(cygnusNebula.priceFeeds[i])), uint256(price));

            // Value = Token Price / Token Weight
            int256 value = int256(adjustedPrice).div(int256(weights[i]));

            // Individual Pi = Value ** Token Weight
            int256 indivPi = value.pow(int256(weights[i]));

            // Adjust total Pi
            totalPi = totalPi.mul(indivPi);
        }

        // 3. Get invariant from the pool
        int256 invariant = int256(IWeightedPool(lpTokenPair).getInvariant());

        // TVL of the pool
        int256 numerator = totalPi.mul(invariant);

        // 4. Total Supply of BPT tokens for this pool
        int256 totalSupply = int256(IWeightedPool(lpTokenPair).totalSupply());

        // 5. BPT Price (USD) = TVL / totalSupply
        uint256 lpPrice = uint256((numerator.toInt().div(totalSupply)));

        // 6. Denominate price in denom token
        (, int256 latestRoundUsd, , , ) = denominationAggregator.latestRoundData();

        // Adjust price of denom token aggregator to 18 decimals
        uint256 adjustedUsdPrice = normalize(IERC20(address(denominationAggregator)), uint256(latestRoundUsd));

        // BPT Price in denom token (USDC) and adjust to `decimals`
        lpTokenPrice = lpPrice.div(adjustedUsdPrice) / 10 ** (18 - decimals);
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     */
    function assetPricesUsd(address lpTokenPair) external view override returns (uint256[] memory) {
        // Load to memory
        CygnusNebula memory cygnusNebula = nebulas[lpTokenPair];

        /// custom:error PairNotInitialized Avoid getting price unless lpTokenPair's price is being tracked
        if (!cygnusNebula.initialized) {
            revert CygnusNebulaOracle__PairNotInitialized(lpTokenPair);
        }

        // Price of denom token
        (, int256 latestRoundUsd, , , ) = denominationAggregator.latestRoundData();

        // Adjust price of denom token aggregator to 18 decimals
        uint256 adjustedUsdPrice = normalize(IERC20(address(denominationAggregator)), uint256(latestRoundUsd));

        // Create new array of poolTokens.length to return
        uint256[] memory prices = new uint256[](cygnusNebula.poolTokens.length);

        // Loop through each token
        for (uint256 i = 0; i < cygnusNebula.poolTokens.length; i++) {
            // Get the price from chainlink from cached price feeds
            (, int256 price, , , ) = cygnusNebula.priceFeeds[i].latestRoundData();

            // Adjust to 18 decimals
            uint256 adjustedPrice = normalize(IERC20(address(cygnusNebula.priceFeeds[i])), uint256(price));

            // Adjust by denom token decimals
            prices[i] = adjustedPrice.div(adjustedUsdPrice) / (10 ** (18 - decimals));
        }

        // Return uint256[] of token prices denominated in denom token and oracle decimals
        return prices;
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            6. NON-CONSTANT FUNCTIONS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── External ───────────────────────────────────────────────  */

    /**
     *  @notice Order of price feeds is important and should match tokens[], unlike x*y=k oracle
     *  @inheritdoc ICygnusNebulaOracle
     *  @custom:security non-reentrant only-admin
     */
    function initializeNebula(
        address lpTokenPair,
        AggregatorV3Interface[] calldata priceFeeds
    ) external override nonReentrant cygnusAdmin {
        // Load to storage
        CygnusNebula storage cygnusNebula = nebulas[lpTokenPair];

        /// @custom:error PairIsinitialized Avoid duplicate oracle
        if (cygnusNebula.initialized) {
            revert CygnusNebulaOracle__PairAlreadyInitialized(lpTokenPair);
        }

        // Bytes32 Pool ID to identify pool in vault
        bytes32 poolId = IWeightedPool(lpTokenPair).getPoolId();

        // Get pool tokens from the vault
        (IERC20[] memory tokens, , ) = VAULT.getPoolTokens(poolId);

        // Decimals for each token
        uint256[] memory tokenDecimals = new uint256[](tokens.length);

        // Loop through each, update tokens and cache scalars for tokens and price feeds
        for (uint256 i = 0; i < tokens.length; i++) {
            // Cache scalar of the token
            computeScalar(tokens[i]);

            // Cache scalar of the price feed
            computeScalar(IERC20(address(priceFeeds[i])));

            // Assign decimals
            tokenDecimals[i] = tokens[i].decimals();
        }

        // Assign id for this BPT
        cygnusNebula.oracleId = nebulaSize();

        // Human friendly name of this LP
        cygnusNebula.name = IERC20(lpTokenPair).name();

        // Store LP Token address
        cygnusNebula.underlying = lpTokenPair;

        // Store pool tokens
        cygnusNebula.poolTokens = tokens;

        // Decimals of each token
        cygnusNebula.tokenDecimals = tokenDecimals;

        // Store price feeds
        cygnusNebula.priceFeeds = priceFeeds;

        // Store oracle status
        cygnusNebula.initialized = true;

        // Add to list
        allNebulas.push(lpTokenPair);

        /// @custom:event InitializeCygnusNebula
        emit InitializeCygnusNebula(true, cygnusNebula.oracleId, lpTokenPair, tokens, tokenDecimals, priceFeeds);
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     *  @custom:security non-reentrant only-admin
     */
    function setOraclePendingAdmin(address newPendingAdmin) external override nonReentrant cygnusAdmin {
        // Pending admin initial is always zero
        /// @custom:error PendingAdminAlreadySet Avoid setting the same pending admin twice
        if (newPendingAdmin == pendingAdmin) {
            revert CygnusNebulaOracle__PendingAdminAlreadySet(newPendingAdmin);
        }

        // Assign address of the requested admin
        pendingAdmin = newPendingAdmin;

        /// @custom:event NewOraclePendingAdmin
        emit NewOraclePendingAdmin(admin, newPendingAdmin);
    }

    /**
     *  @inheritdoc ICygnusNebulaOracle
     *  @custom:security non-reentrant only-admin
     */
    function setOracleAdmin() external override nonReentrant cygnusAdmin {
        /// @custom:error AdminCantBeZero Avoid settings the admin to the zero address
        if (pendingAdmin == address(0)) {
            revert CygnusNebulaOracle__AdminCantBeZero(pendingAdmin);
        }

        // Address of the Admin up until now
        address oldAdmin = admin;

        // Assign new admin
        admin = pendingAdmin;

        // Gas refund
        delete pendingAdmin;

        // @custom:event NewOracleAdmin
        emit NewOracleAdmin(oldAdmin, admin);
    }
}
