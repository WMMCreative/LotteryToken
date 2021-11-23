// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./math/IterableMapping.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./misc/LotteryTracker.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LotteryToken is ERC20, Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    bool private swapping;
    bool private isAlreadyCalled;
    bool private isLotteryActive;

    struct BuyFee {
        uint16 liquidityFee;
        uint16 marketingFee;
        uint16 devFee;
        uint16 lotteryFee;
    }

    struct SellFee {
        uint16 liquidityFee;
        uint16 marketingFee;
        uint16 devFee;
        uint16 lotteryFee;
    }

    BuyFee public buyFee;
    SellFee public sellFee;
    uint16 private totalBuyFee;
    uint16 private totalSellFee;

    LotteryTracker public lotteryTracker;

    address private constant deadWallet = address(0xdead);
    address private constant BUSD =
        address(0x77c21c770Db1156e271a3516F89380BA53D594FA); //BUSD

    uint256 public swapTokensAtAmount = 2 * 10**6 * 10**18;
    uint256 public maxTxAmount = 1 * 10**7 * 10**18;
    uint256 public maxWalletAmount = 5 * 10**7 * 10**18;

    address payable public _marketingWallet = payable(address(0x123));
    address payable public _devWallet = payable(address(0x456));

    // exlcude from fees and max transaction amount
    mapping(address => bool) private _isExcludedFromFees;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    event UpdateUniswapV2Router(
        address indexed newAddress,
        address indexed oldAddress
    );

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event LiquidityWalletUpdated(
        address indexed newLiquidityWallet,
        address indexed oldLiquidityWallet
    );

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event SendLottery(uint256 amount);

    modifier onlyLottery() {
        require(msg.sender == address(lotteryTracker), "Only lottery contract");
        _;
    }

    constructor() ERC20("Lottery TOKEN", "LTKN") {
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3
        );

        buyFee.liquidityFee = 20;
        buyFee.marketingFee = 10;
        buyFee.devFee = 10;
        buyFee.lotteryFee = 20;
        totalBuyFee = 60;

        sellFee.liquidityFee = 30;
        sellFee.marketingFee = 15;
        sellFee.devFee = 15;
        sellFee.lotteryFee = 30;
        totalSellFee = 90;

        // Create a uniswap pair for this new token
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;

        lotteryTracker = new LotteryTracker();

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        lotteryTracker.excludedFromHourly(uniswapV2Pair);
        lotteryTracker.excludedFromHourly(deadWallet);
        lotteryTracker.excludedFromHourly(address(this));

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(_marketingWallet, true);
        excludeFromFees(_devWallet, true);
        excludeFromFees(address(this), true);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), 1 * 10**9 * 10**18);
    }

    receive() external payable {}

    function updateUniswapV2Router(address newAddress) public onlyOwner {
        require(
            newAddress != address(uniswapV2Router),
            "Lottery: The router already has that address"
        );
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
        address _uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());
        uniswapV2Pair = _uniswapV2Pair;
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(
            _isExcludedFromFees[account] != excluded,
            "Lottery: Account is already excluded"
        );
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(
        address[] calldata accounts,
        bool excluded
    ) public onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setSwapAtAmount(uint256 value) external onlyOwner {
        swapTokensAtAmount = value;
    }

    function setMaxWallet(uint256 value) external onlyOwner {
        maxWalletAmount = value;
    }

    function setMaxTx(uint256 value) external onlyOwner {
        maxTxAmount = value;
    }

    function setWallets(address marketing, address dev) external onlyOwner {
        _marketingWallet = payable(marketing);
        _devWallet = payable(dev);
    }

    function setSellFee(
        uint16 lottery,
        uint16 marketing,
        uint16 liquidity,
        uint16 dev
    ) external onlyOwner {
        sellFee.lotteryFee = lottery;
        sellFee.marketingFee = marketing;
        sellFee.liquidityFee = liquidity;
        sellFee.devFee = dev;
        totalSellFee = lottery + marketing + liquidity + dev;
    }

    function setBuyFee(
        uint16 lottery,
        uint16 marketing,
        uint16 liquidity,
        uint16 dev
    ) external onlyOwner {
        buyFee.lotteryFee = lottery;
        buyFee.marketingFee = marketing;
        buyFee.liquidityFee = liquidity;
        buyFee.devFee = dev;
        totalBuyFee = lottery + marketing + liquidity + dev;
    }

    function setLotteryState(bool value) external onlyOwner {
        isLotteryActive = value;
    }

    function setAutomatedMarketMakerPair(address pair, bool value)
        public
        onlyOwner
    {
        require(
            pair != uniswapV2Pair,
            "Lottery: The PancakeSwap pair cannot be removed from automatedMarketMakerPairs"
        );

        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(
            automatedMarketMakerPairs[pair] != value,
            "Lottery: Automated market maker pair is already set to that value"
        );
        automatedMarketMakerPairs[pair] = value;

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function claimStuckTokens(address _token) external onlyOwner {
        require(_token != address(this),"No rugs");
        if (_token == address(0x0)) {
            payable(owner()).transfer(address(this).balance);
            return;
        }
        IERC20 erc20token = IERC20(_token);
        uint256 balance = erc20token.balanceOf(address(this));
        erc20token.transfer(owner(), balance);
    }

    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function excludeFromHourly(address account) external onlyOwner {
        lotteryTracker.excludeFromHourly(account);
    }

    function setMinValues(uint256 _hourly) external onlyOwner {
        lotteryTracker.setMinValues(_hourly);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        uint256 contractTokenBalance = balanceOf(address(this));

        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if (
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            from != owner() &&
            to != owner()
        ) {
            swapping = true;

            contractTokenBalance = swapTokensAtAmount;

            uint256 feeTokens = contractTokenBalance
                .mul(
                    buyFee.marketingFee +
                        buyFee.devFee +
                        sellFee.marketingFee +
                        sellFee.devFee
                )
                .div(totalBuyFee + totalSellFee);
            swapAndSendToFee(feeTokens);

            uint256 swapTokens = contractTokenBalance
                .mul(buyFee.liquidityFee + sellFee.liquidityFee)
                .div(totalBuyFee + totalSellFee);
            swapAndLiquify(swapTokens);

            uint256 sellTokens = contractTokenBalance
                .mul(buyFee.lotteryFee + sellFee.lotteryFee)
                .div(totalBuyFee + totalSellFee);
            swapAndSendLottery(sellTokens);

            swapping = false;
        }

        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if (takeFee) {
            require(amount <= maxTxAmount,"Amount exceeds limit");

            if(!automatedMarketMakerPairs[to]){
                require(balanceOf(to) + amount <= maxWalletAmount,"Balance exceeds limit");
            }
            
            uint256 fees;

            if(automatedMarketMakerPairs[to]) {
                fees = totalSellFee;
            }else if(automatedMarketMakerPairs[from]){
                fees = totalBuyFee;
            }
            uint256 feeAmount = amount.mul(fees).div(1000);

            amount = amount.sub(feeAmount);

            super._transfer(from, address(this), feeAmount);
        }

        super._transfer(from, to, amount);

        try
            lotteryTracker.setAccount(payable(from), balanceOf(from))
        {} catch {}
        try lotteryTracker.setAccount(payable(to), balanceOf(to)) {} catch {}

        if (isLotteryActive) {
            if (
                block.timestamp >=
                lotteryTracker.lastHourlyDistributed() + 1 hours
            ) {
                if (!isAlreadyCalled) {
                    lotteryTracker.getRandomNumber();
                    isAlreadyCalled = true;
                } else {
                    try lotteryTracker.pickHourlyWinners() {
                        isAlreadyCalled = false;
                    } catch {}
                }
            }
        }
    }

    function swapAndSendToFee(uint256 tokens) private {
        uint256 initialBUSDBalance = IERC20(BUSD).balanceOf(address(this));
        swapTokensForBUSD(tokens);
        uint256 newBalance = (IERC20(BUSD).balanceOf(address(this))).sub(
            initialBUSDBalance
        );

        uint16 total = buyFee.marketingFee +
                        buyFee.devFee +
                        sellFee.marketingFee +
                        sellFee.devFee;

        uint256 marketingShare = newBalance.mul(buyFee.marketingFee + sellFee.marketingFee).div(total);
        uint256 devShare = newBalance.sub(marketingShare);

        IERC20(BUSD).transfer(_marketingWallet, marketingShare);
        IERC20(BUSD).transfer(_devWallet, devShare);
    }

    function swapAndSendLottery(uint256 tokens) private {
        uint256 initialBUSDBalance = IERC20(BUSD).balanceOf(address(this));
        swapTokensForBUSD(tokens);
        uint256 newBalance = (IERC20(BUSD).balanceOf(address(this))).sub(
            initialBUSDBalance
        );

        IERC20(BUSD).transfer(address(lotteryTracker), newBalance);

        lotteryTracker.setLottery(newBalance);

        emit SendLottery(newBalance);
    }

    function swapAndLiquify(uint256 tokens) private {
        // split the contract balance into halves
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function swapTokensForBUSD(uint256 tokenAmount) private {
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        path[2] = BUSD;

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0),
            block.timestamp
        );
    }
}
