// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


import {OptionPrice, IUniswapV3Pool} from "./OptionPrice.sol";

import {IOptionToken} from "./IOptionToken.sol";
import {IPermit2} from "./IPermit2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {console} from "forge-std/console.sol";
import {NonzeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonzeroDeltaCount.sol";

uint160 constant SQRT_PRICE_X96 = 1<<96;
int24 constant TICK_SPACING = type(int16).max;

struct OptionPool {
    address collateral;
    address optionToken;
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
    uint160 sqrtPriceX96;
    uint256 expiration;
    uint256 strike;
}

struct CurrentOptionPrice {
    address collateral;
    address optionToken;
    uint256 price;
    uint256 collateralPrice;
}

struct Amount {
    uint256 collateralAmount;
    int128 collateralAmount_;
    uint256 cashAmount;
    int128 cashAmount_;
    uint256 amount;
    int128 amount_;
    uint256 collateralPrice;
    uint256 price;
    address option;
    Currency cashCurrency;
    Currency optionCurrency;
    bool cashForOption;
}

contract OpHook is BaseHook, ERC4626, Ownable, ReentrancyGuard, Pausable {
    using PoolIdLibrary for PoolKey;
    using Math for uint256;
    using SafeERC20 for IERC20;

    // ============ Events ============
    
    event FeeCollected(address indexed from, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeRateUpdated(uint256 oldRate, uint256 newRate);
    event OptionPoolUpdated(address indexed oldPool, address indexed newPool);
    event EmergencyWithdraw(address indexed owner, uint256 amount);
    event Swap(address, address, uint256, uint256, uint256);

    OptionPrice public optionPrice;

    IERC20 public collateral;
    IERC20 public cash;
    IUniswapV3Pool public pricePool;
    address public cashToken;
    address public collateralToken;
    bool public collateralIsOne;
    uint8 decimals0;
    uint8 decimals1;
    uint256 power;


    IPermit2 public immutable PERMIT2;
    address public pmAddress;

    OptionPool[] public pools;
    mapping(address => bool) public options;

    constructor(IPoolManager _poolManager, address permit2, address _collateral, address _cash, string memory _name, string memory _symbol, address _pricePool) 
    BaseHook() 
    ERC4626(IERC20(_collateral)) 
    ERC20(_name, _symbol) 
    Ownable(msg.sender) {
        optionPrice = new OptionPrice();
        PERMIT2 = IPermit2(permit2);
        pmAddress = address(_poolManager);




        collateralToken = _collateral;
        cashToken = _cash;
        collateral = IERC20(_collateral);
        cash = IERC20(cashToken);

        pricePool = IUniswapV3Pool(_pricePool);
        collateralIsOne = address(collateral) > address(cash);
        decimals0 = IERC20Metadata(pricePool.token0()).decimals();
        decimals1 = IERC20Metadata(pricePool.token1()).decimals();
        power = 10 ** (decimals1 >= decimals0 ? decimals1 - decimals0 : decimals0 - decimals1);


    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    function calculateValues(Currency token0, Currency token1, int256 amountSpecified, bool zeroForOne) internal view returns (Amount memory amounts){
        address option;
        Currency optionCurrency;
        Currency cashCurrency;
        address token0_ = Currency.unwrap(token0);
        address token1_ = Currency.unwrap(token1);
        bool cashForOption;
        if (options[token1_]){
            option = token1_;
            optionCurrency = token1;
            cashCurrency = token0;
            cashForOption = zeroForOne;
        } else if (options[token0_]){
            option = token0_;
            optionCurrency = token0;
            cashCurrency = token1;
            cashForOption = !zeroForOne;
        } else {
            revert("Token not whitelisted");
        }
        require(amountSpecified < 0, "amountSpecified must be negative");
        uint256 amount = uint256(-amountSpecified);
        int128 amount_ = SafeCast.toInt128(int256(amount));
        uint256 collateralPrice = getCollateralPrice();
        uint256 price = getPrice(collateralPrice, option);

        uint256 collateralAmount = calculateCollateral(amount, price);
        int128 collateralAmount_ = SafeCast.toInt128(int256(collateralAmount));
        uint256 cashAmount = Math.mulDiv(amount, 1e36, price);
        int128 cashAmount_ = SafeCast.toInt128(int256(cashAmount));
        console.log("token0", token0_);
        console.log("token1", token1_);
        console.log("cashforOption", cashForOption);
        amounts = Amount({
            amount:amount,
            amount_:amount_,
            collateralAmount:collateralAmount,
            collateralAmount_:collateralAmount_,
            cashAmount:cashAmount,
            cashAmount_:cashAmount_,
            price:price,
            collateralPrice:collateralPrice,
            option:option,
            cashCurrency:cashCurrency,
            optionCurrency:optionCurrency,
            cashForOption:cashForOption
            }
        );
    }

    function availableCollateral() external view returns (uint256){
        return collateral.balanceOf(address(this));
    }

    function calculateCash(uint256 collateralAmount, uint256 price) public pure returns (uint256){
        return Math.mulDiv(collateralAmount, 1e36, price);
    }

    function calculateCollateral(uint256 cashAmount, uint256 price) public pure returns (uint256){
        return Math.mulDiv(cashAmount, price, 1e18);
    }

    function transferCash(uint256 cashAmount) internal returns (uint256 cashTransferred){
        uint256 initialCash = cash.balanceOf(address(this));
        cash.safeTransferFrom(msg.sender, address(this), cashAmount);
        cashTransferred = cash.balanceOf(address(this)) - initialCash;
        require(cashTransferred > 0, "No Cash Transferred in");
    }

    function swap(address optionToken, uint256 cashAmount, address to) external nonReentrant {
        require(cashAmount > 0, "amountA=0");
        require(to != address(0), "bad to");
        require(options[optionToken], "option not part of group");

        Amount memory a = calculateValues(Currency.wrap(cashToken), Currency.wrap(optionToken), -int256(cashAmount), true);
        IOptionToken option = IOptionToken(optionToken);

        if(collateral.balanceOf(address(this)) < a.collateralAmount){
            cashAmount = calculateCash(collateral.balanceOf(address(this)), a.price);
        }
        uint256 cashTransferred = transferCash(cashAmount);

        uint256 optionAmount = calculateCollateral(cashTransferred, a.price);

        option.mint(optionAmount);
        option.transfer(to, optionAmount);

        emit Swap(msg.sender, to, cashTransferred, optionAmount, a.price);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 zeroReturn){
        require(params.amountSpecified < 0, "amountSpecified must be negative");
        zeroReturn = 0;
        selector = BaseHook.beforeSwap.selector;
        Amount memory a = calculateValues(
            key.currency0, 
            key.currency1, 
            params.amountSpecified,
            params.zeroForOne
            );
        IOptionToken option = IOptionToken(a.option);
        require(option.expirationDate() > block.timestamp, "Option expired");

        if (a.cashForOption) {
            // Here we JIT create option tokens and let the flash accounting handle transfers
            option.mint(a.collateralAmount);
            poolManager().take(a.cashCurrency, address(this), a.amount);
            poolManager().sync(a.optionCurrency);
            option.transfer(pmAddress, a.collateralAmount);
            poolManager().settle();
            delta = toBeforeSwapDelta(a.amount_, -a.collateralAmount_);
        } else {
            // Here we have to take the option tokens from the caller and burn them
            poolManager().take(a.optionCurrency, address(this), a.amount);
            poolManager().sync(a.cashCurrency);
            cash.safeTransfer(pmAddress, a.cashAmount);
            poolManager().settle();
            option.redeem(a.amount);
            delta = toBeforeSwapDelta(a.cashAmount_, -a.amount_);
        }
    }

    function _beforeAddLiquidity(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        
        returns (bytes4, BeforeSwapDelta, uint24){
            revert("Cannot Add Liquidity to This Pool ");
        }

    function _beforeDonate(address, PoolKey calldata, SwapParams calldata, bytes calldata) internal pure returns (bytes4, BeforeSwapDelta, uint24){
            revert("Cannot Donate to This Pool");
        }

    
    function getPriceX64(uint160 sqrtPriceX96) public pure returns (uint256) {
        uint256 sqrtPriceX32 = (uint256(sqrtPriceX96)>>64);
        // priceX96 is Q64.96, so we square to get the ratio
        return uint256(sqrtPriceX32) * uint256(sqrtPriceX32);
    }

    // Returns price of 1 token0 in token1 with 18 decimals precision
    // How much token1 you need to buy 1 token0 is sqrtPriceX96
    function getCollateralPrice() public view returns (uint256 price) {

        (uint160 sqrtPriceX96,,,,,,) = pricePool.slot0();
        // Calculate price with proper scaling
        // priceX192 is in Q192.192 format, we need to extract the integer part
        // uint256 priceX96 = priceX64 >> 96; // Convert from Q192.192 to Q96.96
        price = (getPriceX64(sqrtPriceX96) * 10**18) >> 64; // Convert from Q96.96 to 1e18 fixed point
        price = decimals1>decimals0 ? (price / power) : (price * power);
 
        if (collateralIsOne) {
            require(price > 0, "Price cannot be zero for inverse calculation");
            price = 1e36 / price;
        }

        return price;
    }

    function getPrice( address option_) public view returns (uint256) {
        return getPrice(getCollateralPrice(), option_);
    }

    function getPrice(uint256 collateralPrice, address option_) public view returns (uint256) {
        IOptionToken option = IOptionToken(option_);
        return optionPrice.getPrice(collateralPrice, option.strike(), option.expirationDate(), option.isPut(), false);
    }

    function getPrices() public view returns (CurrentOptionPrice[] memory prices) {
        prices = new CurrentOptionPrice[](pools.length);
        uint256 collateralPrice = getCollateralPrice();
        for (uint256 i = 0; i < pools.length; i++) {
                prices[i] =  CurrentOptionPrice({
                    collateralPrice: collateralPrice,
                    collateral: address(collateral),
                    optionToken: pools[i].optionToken,
                    price: getPrice(collateralPrice, pools[i].optionToken)
            });
        }
    }

    function initPool(
        address optionToken,
        uint24 fee
    ) public returns (PoolKey memory) {

        IOptionToken optionToken_ = IOptionToken(optionToken);
        uint256 expiration = optionToken_.expirationDate();
        address token0 = cashToken < optionToken ? cashToken : optionToken;
        address token1 = cashToken < optionToken ? optionToken : cashToken;

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
        poolManager().initialize(poolKey, SQRT_PRICE_X96);

        OptionPool memory pool = OptionPool({
            collateral: address(collateral),
            token0: token0,
            token1: token1,
            fee: fee,
            tickSpacing: TICK_SPACING,
            sqrtPriceX96: SQRT_PRICE_X96,  //todo: verify this
            optionToken: optionToken,
            expiration: expiration,
            strike: optionToken_.strike()
        });
        pools.push(pool);
        options[optionToken] = true;
        return poolKey;
    }

    // ============ ERC4626 Overrides ============
    
    function deposit(uint256 assets, address receiver) 
        public 
        override 
        whenNotPaused 
        nonReentrant 
        returns (uint256 shares) 
    {
        
        shares = super.deposit(assets, receiver);
        
        // Additional logic for option pool integration can be added here
        _afterDeposit(assets, shares, receiver);
        
        return shares;
    }
    
    function mint(uint256 shares, address receiver) 
        public 
        override 
        whenNotPaused 
        nonReentrant 
        returns (uint256 assets) 
    {
        require(shares > 0, "OptionPoolVault: zero shares");
        
        assets = super.mint(shares, receiver);
        
        // Additional logic for option pool integration can be added here
        _afterMint(assets, shares, receiver);
        
        return assets;
    }
    
    function withdraw(uint256 assets, address receiver, address owner) 
        public 
        override 
        whenNotPaused 
        nonReentrant 
        returns (uint256 shares) 
    {
        shares = super.withdraw(assets, receiver, owner);
        
        // Additional logic for option pool integration can be added here
        _afterWithdraw(assets, shares, receiver, owner);
        
        return shares;
    }
    
    function redeem(uint256 shares, address receiver, address owner) 
        public 
        override 
        whenNotPaused 
        nonReentrant 
        returns (uint256 assets) 
    {
        assets = super.redeem(shares, receiver, owner);
        
        // Additional logic for option pool integration can be added here
        _afterRedeem(assets, shares, receiver, owner);
        
        return assets;
    }

    // ============ View Functions ============
    
    /**
     * @dev Get vault statistics
     * @return totalAssets_ Total assets in the vault
     * @return totalShares_ Total shares minted
     * @return exchangeRate_ Current exchange rate (assets per share)
     * @return utilizationRate_ Current utilization rate
     */
    function getVaultStats() external view returns (
        uint256 totalAssets_,
        uint256 totalShares_,
        uint256 exchangeRate_,
        uint256 utilizationRate_
    ) {
        totalAssets_ = totalAssets();
        totalShares_ = totalSupply();
        exchangeRate_ = totalShares_ > 0 ? totalAssets_ * 1e18 / totalShares_ : 1e18;
        utilizationRate_ =  0;
    }

    // ============ Internal Hooks ============
    
    /**
     * @dev Hook called after deposit
     * @param assets Amount of assets deposited
     * @param shares Amount of shares minted
     * @param receiver Address receiving the shares
     */
    function _afterDeposit(uint256 assets, uint256 shares, address receiver) internal virtual {
        // Override in child contracts to add custom logic
    }
    
    /**
     * @dev Hook called after mint
     * @param assets Amount of assets deposited
     * @param shares Amount of shares minted
     * @param receiver Address receiving the shares
     */
    function _afterMint(uint256 assets, uint256 shares, address receiver) internal virtual {
        // Override in child contracts to add custom logic
    }
    
    /**
     * @dev Hook called after withdraw
     * @param assets Amount of assets withdrawn
     * @param shares Amount of shares burned
     * @param receiver Address receiving the assets
     * @param owner Address that owned the shares
     */
    function _afterWithdraw(uint256 assets, uint256 shares, address receiver, address owner) internal virtual {
        // Override in child contracts to add custom logic
    }
    
    /**
     * @dev Hook called after redeem
     * @param assets Amount of assets withdrawn
     * @param shares Amount of shares burned
     * @param receiver Address receiving the assets
     * @param owner Address that owned the shares
     */
    function _afterRedeem(uint256 assets, uint256 shares, address receiver, address owner) internal virtual {
        // Override in child contracts to add custom logic
    }

    // ============ ERC4626 Required Overrides ============
    
    /**
     * @dev Override to implement custom conversion logic if needed
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) 
        internal 
        view 
        virtual 
        override 
        returns (uint256 shares) 
    {
        return super._convertToShares(assets, rounding);
    }
    
    /**
     * @dev Override to implement custom conversion logic if needed
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) 
        internal 
        view 
        virtual 
        override 
        returns (uint256 assets) 
    {
        return super._convertToAssets(shares, rounding);
    }
    
    /**
     * @dev Override to implement custom deposit logic if needed
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) 
        internal 
        virtual 
        override 
    {
        super._deposit(caller, receiver, assets, shares);
    }
    
    /**
     * @dev Override to implement custom withdraw logic if needed
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) 
        internal 
        virtual 
        override 
    {
        super._withdraw(caller, receiver, owner, assets, shares);
    }

}
