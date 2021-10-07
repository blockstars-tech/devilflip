// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";

import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IPancakeV2Factory.sol";
import "./interfaces/IPancakeswapV2Pair.sol";

contract DevilFlip is
    IERC20,
    IERC20Metadata,
    Context,
    Ownable,
    VRFConsumerBase
{
    string private _name;
    string private _symbol;

    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    uint256 public nextSpinTimestamp;
    bool public isLocked;
    bool private inSwapAndLiquify;

    // eg. 0.01, 0.1 ... 1, 10, 100
    uint32 public constant FEE_DECIMALS = 2;

    // Wagyu
    address public WAGYU_DEV_TEAM;
    address public WAGYU;

    uint256 public devilAccountScore; // Counts in DFLIP
    uint256 public angelAccountScore; // Counts in WBNB

    // Configurable Fees
    // Consider the fee decimals:
    // 1 = 0.01%, 10 = 0.1%, 100 = 1%, 1.000 = 10%, 10.000 = 100%
    uint32 public FEE_GAME_TOKENOMICS = 500;
    uint32 public FEE_WAGYU_DEV_TEAM = 200;
    uint32 public FEE_WAGYU_BUYBACK = 200;
    uint32 public FEE_LIQUIDITY_POOL = 100;

    mapping(address => bool) private _isExcludedFromFee;

    // Token Addresses
    address public WBNB;

    // Zero Address
    address public constant ZERO_ADDRESS =
        0x0000000000000000000000000000000000000000;

    // PancakeSwap Router Address
    IPancakeRouter02 public immutable PancakeSwapRouter;
    address public pancakeswapV2Pair;

    mapping(address => bool) private _isPancakeSwapPair;

    uint256 private _gameTokenomicsFeeOnHold;
    uint256 private _liquidityPoolFeeOnHold;
    uint256 private _BNBAmountOnHold;
    uint256 private _lastReserveBlockTimestamp;

    // ChainLink
    // Binance Smart Chain
    // LINK Token	                    0x404460C6A5EdE2D891e8297795264fDe62ADBB75
    // VRF Coordinator	                0x747973a5A2a4Ae1D3a8fDF5479f1514F65Db9C31
    // Key Hash	                        0xc251acd21ec4fb7f31bb8868288bfdbaeb4fbfec2df3735ddbd4f7dc8d60103c
    // Fee	                            0.2 LINK
    address public VRFCoordinator = 0x747973a5A2a4Ae1D3a8fDF5479f1514F65Db9C31;
    address public LINKAddress = 0x404460C6A5EdE2D891e8297795264fDe62ADBB75;
    bytes32 internal keyHash =
        0xc251acd21ec4fb7f31bb8868288bfdbaeb4fbfec2df3735ddbd4f7dc8d60103c;
    uint256 internal fee = 2 * 10**17;
    bytes32 private lastRequestId;
    uint256 public lastRandomResult;

    event GameTokenomicsTransactionFeeCollected(uint256 amount);
    event WagyuDevTeamTransactionFeeCollected(uint256 amount);
    event WagyuBuybackTransactionFeeCollected(uint256 amount);
    event LiquidityPoolTransactionFeeCollected(uint256 amount);
    event Winner(uint256 winnerIndex);

    modifier lock() {
        require(
            !isLocked,
            "During 'dumping' or 'pumping' transactions will be reverted"
        );
        _;
    }

    modifier lockTheSwap() {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(address wagyuAddress, address wagyuDevTeamAddress)
        VRFConsumerBase(VRFCoordinator, LINKAddress)
    {
        _name = "DevilFlip";
        _symbol = "DFLIP";

        WAGYU = wagyuAddress;
        WAGYU_DEV_TEAM = wagyuDevTeamAddress;

        nextSpinTimestamp = block.timestamp + 1 days;

        IPancakeRouter02 _pancakeswapV2Router = IPancakeRouter02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        WBNB = _pancakeswapV2Router.WETH();

        _isExcludedFromFee[_msgSender()] = true;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[address(_pancakeswapV2Router)] = true;

        /// @notice We are going to creat PancakeSwapV2 Pair and add it to the list of Pairs
        pancakeswapV2Pair = IPancakeV2Factory(_pancakeswapV2Router.factory())
            .createPair(address(this), WBNB);
        _isPancakeSwapPair[pancakeswapV2Pair] = true;

        PancakeSwapRouter = _pancakeswapV2Router;

        // FIXME: Here should be initial mint amount
        uint256 initialTokenAmount = 1000000 * 10**18; // 1 m
        _mint(_msgSender(), initialTokenAmount);

        emit Transfer(ZERO_ADDRESS, _msgSender(), initialTokenAmount);
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount)
        public
        override
        lock
        returns (bool)
    {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount)
        public
        override
        lock
        returns (bool)
    {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override lock returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(
            currentAllowance >= amount,
            "ERC20: transfer amount exceeds allowance"
        );
        unchecked {
            _approve(sender, _msgSender(), currentAllowance - amount);
        }

        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        public
        returns (bool)
    {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender] + addedValue
        );
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        returns (bool)
    {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(
            currentAllowance >= subtractedValue,
            "ERC20: decreased allowance below zero"
        );
        unchecked {
            _approve(_msgSender(), spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `sender` to `recipient`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint256 senderBalance = _balances[sender];
        require(
            senderBalance >= amount,
            "ERC20: transfer amount exceeds balance"
        );
        unchecked {
            _balances[sender] = senderBalance - amount;
        }

        // If contract transfers or someone transfers to contract the fee will not be charged
        // Checks whether we are transfering to contract or contract transfers
        // Fees will not be charged in this way
        // If contract transfers or someone transfers to contract the fee will not be charged

        bool takeFee = true;

        if (_isExcludedFromFee[sender] || _isExcludedFromFee[sender]) {
            takeFee = false;
        }

        _tokenTransfer(sender, recipient, amount, takeFee);
    }

    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 amount,
        bool takeFee
    ) private {
        if (takeFee) {
            require(
                !isLocked,
                "During 'dumping' or 'pumping' transactions are reverted"
            );
            if (_isPancakeSwapPair[sender] || _isPancakeSwapPair[recipient]) {
                /*
                    fees[1] - Gametokenomics Fee
                    fees[2] - Devteam Fee
                    fees[3] - Wagyu Fee
                    fees[4] - Liquidity Fee
                    fees[0] - Transfer amount less fees
                */
                uint256[5] memory fees = _calculateFees(amount);

                chargeGametokenomicsFee(fees[1]);

                _balances[WAGYU_DEV_TEAM] += fees[2];
                emit WagyuDevTeamTransactionFeeCollected(fees[2]);

                chargeBuybackFee(fees[3]);

                chargeLiquidityFee(fees[4]);

                amount = fees[0];
            }
        }

        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }

    function _calculateFees(uint256 amount)
        private
        view
        returns (uint256[5] memory)
    {
        uint256[5] memory fees;

        fees[1] = (amount * FEE_GAME_TOKENOMICS) / (10**FEE_DECIMALS * 100); // Gametokenomics Fee
        fees[2] = (amount * FEE_WAGYU_DEV_TEAM) / (10**FEE_DECIMALS * 100); // Devteam Fee
        fees[3] = (amount * FEE_WAGYU_BUYBACK) / (10**FEE_DECIMALS * 100); // Wagyu Fee
        fees[4] = (amount * FEE_LIQUIDITY_POOL) / (10**FEE_DECIMALS * 100); // Liquidity Fee

        fees[0] = amount - fees[1] - fees[2] - fees[3] - fees[4]; // Net transfer amount

        return fees;
    }

    function chargeLiquidityFee(uint256 feeAmount) internal {
        if (feeAmount != 0) {
            uint256 half = feeAmount / 2;
            uint256 otherHalf = feeAmount - half;

            if (_isPancakeSwapPair[msg.sender]) {
                _liquidityPoolFeeOnHold += feeAmount;
                _balances[address(this)] += feeAmount;
            } else {
                if (_liquidityPoolFeeOnHold != 0) {
                    uint256 halfOfHolding = _liquidityPoolFeeOnHold / 2;
                    uint256 otherHalfOfHolding = _liquidityPoolFeeOnHold -
                        halfOfHolding;
                    uint256 bnbAmountOnHold = swapDFLIPForBNBSupportingFees(
                        otherHalfOfHolding,
                        address(this)
                    );
                    addLiquidity(halfOfHolding, bnbAmountOnHold);
                    _liquidityPoolFeeOnHold = 0;
                }

                _balances[address(this)] += feeAmount;
                uint256 bnbAmount = swapDFLIPForBNBSupportingFees(
                    otherHalf,
                    address(this)
                );
                addLiquidity(half, bnbAmount);
            }

            emit LiquidityPoolTransactionFeeCollected(feeAmount);
        }
    }

    function chargeBuybackFee(uint256 feeAmount) internal {
        if (feeAmount != 0) {
            // FIXME: This address later will be replaced probably with swap logic
            _balances[address(WAGYU)] += feeAmount;

            emit WagyuBuybackTransactionFeeCollected(feeAmount);
        }
    }

    function chargeGametokenomicsFee(uint256 feeAmount) internal {
        if (feeAmount != 0) {
            // Calculatung 50% of GameTokenomics
            uint256 halfOfTokenomicsFee = feeAmount / 2;
            uint256 otherHalf = feeAmount - halfOfTokenomicsFee;

            /// @notice If we are buying tokens this means that we cannot do any swap/addLiquidity manipulations
            ///         therefore we are collecting gametokenomics and liqudity fee to be chargde in sell phase
            if (_isPancakeSwapPair[msg.sender]) {
                (
                    uint256 reserveIn,
                    uint256 reserveOut,
                    uint256 currentReserveBlockTimestamp
                ) = IPancakeswapV2Pair(pancakeswapV2Pair).getReserves();
                uint256 outputBNBAmount = PancakeSwapRouter.getAmountOut(
                    otherHalf,
                    reserveIn,
                    reserveOut
                );

                if (
                    _lastReserveBlockTimestamp == currentReserveBlockTimestamp
                ) {
                    outputBNBAmount = PancakeSwapRouter.getAmountOut(
                        otherHalf,
                        reserveIn - _gameTokenomicsFeeOnHold,
                        reserveOut - _BNBAmountOnHold
                    );
                }

                _lastReserveBlockTimestamp = currentReserveBlockTimestamp;

                _gameTokenomicsFeeOnHold += otherHalf;
                _balances[address(this)] += otherHalf;

                devilAccountScore += halfOfTokenomicsFee;

                angelAccountScore += outputBNBAmount;
                _BNBAmountOnHold += outputBNBAmount;
            } else {
                if (_gameTokenomicsFeeOnHold != 0) {
                    swapDFLIPForBNBSupportingFees(
                        _gameTokenomicsFeeOnHold,
                        address(this)
                    );
                    _gameTokenomicsFeeOnHold = 0;
                    _BNBAmountOnHold = 0;
                }

                devilAccountScore += halfOfTokenomicsFee;

                _balances[address(this)] += otherHalf;
                uint256 outputBNBAmount = swapDFLIPForBNBSupportingFees(
                    otherHalf,
                    address(this)
                );

                angelAccountScore += outputBNBAmount;
            }

            emit GameTokenomicsTransactionFeeCollected(feeAmount);
        }
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply += amount;
        _balances[account] += amount;

        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /// @notice This function will change current WagyuDevTeam Address
    /// @param newAddress new address parameter
    function setWagyuDevTeamAddress(address newAddress) external onlyOwner {
        require(
            newAddress != WAGYU_DEV_TEAM,
            "Provided address is already set"
        );

        WAGYU_DEV_TEAM = newAddress;
    }

    /// @notice This function changes current GameTokenomics Fee
    /// @notice Provided Fee value will be charged for each transaction
    /// @param newValue uint32 new fee falue
    function setGameTokenomicsFee(uint32 newValue) external onlyOwner {
        require(
            FEE_GAME_TOKENOMICS != newValue,
            "Provided fee value is already set"
        );
        require(newValue <= 10000, "Provided fee value is greater than 100%");

        FEE_GAME_TOKENOMICS = newValue;
    }

    /// @notice This function changes current WagyDevTeam Fee
    /// @notice Provided Fee value will be charged for each transaction
    /// @param newValue uint32 new fee falue
    function setWagyuDevTeamFee(uint32 newValue) external onlyOwner {
        require(
            FEE_WAGYU_DEV_TEAM != newValue,
            "Provided fee value is already set"
        );
        require(newValue <= 10000, "Provided fee value is greater than 100%");

        FEE_WAGYU_DEV_TEAM = newValue;
    }

    /// @notice This function changes current WagyuBuyback Fee
    /// @notice Provided Fee value will be charged for each transaction
    /// @param newValue uint32 new fee falue
    function setWagyuBuybackFee(uint32 newValue) external onlyOwner {
        require(
            FEE_WAGYU_BUYBACK != newValue,
            "Provided fee value is already set"
        );
        require(newValue <= 10000, "Provided fee value is greater than 100%");

        FEE_WAGYU_BUYBACK = newValue;
    }

    /// @notice This function changes current LiquidityPool Fee
    /// @notice Provided Fee value will be charged for each transaction
    /// @param newValue uint32 new fee falue cannot be the same as current
    function setLiquidityPoolFee(uint32 newValue) external onlyOwner {
        require(
            FEE_LIQUIDITY_POOL != newValue,
            "Provided fee value is already set"
        );
        require(newValue <= 10000, "Provided fee value is greater than 100%");

        FEE_LIQUIDITY_POOL = newValue;
    }

    /// @notice Swaps an exact amount of tokens for as much BNB as possible
    /// @param tokenAmount The amount of input tokens to send
    /// @param to Recipient of BNB
    /// @return Returns uin256 swapped amount
    function swapDFLIPForBNBSupportingFees(uint256 tokenAmount, address to)
        private
        lockTheSwap
        returns (uint256)
    {
        /// @dev path is an array of token addresses. path.length must be >= 2. Pools for each consecutive pair of addresses must exist and have liquidity
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        /// @dev Contract should give the router an allowence to be able to perform swap
        _approve(address(this), address(PancakeSwapRouter), tokenAmount);

        uint256 balanceBefore = address(this).balance;

        PancakeSwapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            to,
            block.timestamp
        );

        return (address(this).balance - balanceBefore);
    }

    /// @notice Adds liquidity to an DFLIP <-> BNB pool with BNB
    /// @param tokenAmount The amount of token to add
    /// @return amountToken The amount of token sent to the pool
    /// @return amountBNB The amount of ETH converted to WETH and sent to the pool
    /// @return liquidity The amount of liquidity tokens minted
    function addLiquidity(uint256 tokenAmount, uint256 bnbAmount)
        private
        returns (
            uint256 amountToken,
            uint256 amountBNB,
            uint256 liquidity
        )
    {
        /// @dev Contract should give the router an allowence to be able to perform swap
        _approve(address(this), address(PancakeSwapRouter), tokenAmount);

        /// @notice The recipient of liquidity tokens will be owner (contract deployer)
        /// @param value: tokenAmount is actually bnbAmount to be sent
        /// @param address(this) is current contracts address (token)
        return
            PancakeSwapRouter.addLiquidityETH{value: bnbAmount}(
                address(this),
                tokenAmount,
                0,
                0,
                owner(),
                block.timestamp
            );
    }

    /// @notice Adds Approved PancakeSwarpPair
    /// @param _address Adds provided address to the mapping
    function addPancakeSwapV2PairAddress(address _address) public onlyOwner {
        require(
            !_isPancakeSwapPair[_address],
            "Provided pair address already exists"
        );
        _isPancakeSwapPair[_address] = true;
    }

    /// @notice Removes Approved PancakeSwarpPair
    /// @param _address Removes provided address from the mapping
    function removePancakeSwapV2PairAddress(address _address) public onlyOwner {
        require(_isPancakeSwapPair[_address], "Provided address doesnt exist");
        _isPancakeSwapPair[_address] = false;
    }

    /// @notice Generates random number via Chainlink VRF
    function spin() public returns (bytes32 requestId) {
        require(
            block.timestamp >= nextSpinTimestamp,
            "It's too early to call this function"
        );
        /// @notice Charges LINK fee from contract address
        require(
            LINK.balanceOf(address(this)) >= fee,
            "Not enough LINK - fill contract with faucet"
        );

        /// @dev Perhaps there are some tokens on hold
        if (_gameTokenomicsFeeOnHold != 0 || _liquidityPoolFeeOnHold != 0) {
            // Gametokenomics
            swapDFLIPForBNBSupportingFees(
                _gameTokenomicsFeeOnHold,
                address(this)
            );
            _gameTokenomicsFeeOnHold = 0;
            _BNBAmountOnHold = 0;

            // Liquidity
            uint256 halfOfHolding = _liquidityPoolFeeOnHold / 2;
            uint256 otherHalfOfHolding = _liquidityPoolFeeOnHold -
                halfOfHolding;
            uint256 bnbAmountOnHold = swapDFLIPForBNBSupportingFees(
                otherHalfOfHolding,
                address(this)
            );
            addLiquidity(halfOfHolding, bnbAmountOnHold);
            _liquidityPoolFeeOnHold = 0;
        }

        isLocked = true;
        return requestRandomness(keyHash, fee);
    }

    /// @notice Callback function used by VRF Coordinator
    function fulfillRandomness(bytes32 requestId, uint256 randomness)
        internal
        override
    {
        lastRandomResult = randomness;
        _spin(lastRandomResult);

        isLocked = false;
    }

    /// @notice Uses random number to choose winner
    /// @param randomNumber uint256 random number generated by ChainLink
    function _spin(uint256 randomNumber) private {
        /// @notice If (randomNumber) % 2 equals:
        //          0 - Devil Wins
        //          1 - Angel Wins
        if ((randomNumber % 2) > 0) {
            // Angel Won

            _balances[address(this)] += devilAccountScore;
            uint256 outputBNBAmount = swapDFLIPForBNBSupportingFees(
                devilAccountScore,
                address(this)
            );

            devilAccountScore = 0;
            angelAccountScore += outputBNBAmount;

            emit Winner(1);
        } else {
            // Devil Won
            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = address(this);

            // NOTE: We cannot swap ETH to Token and transfer received Token to its contract
            uint256[] memory amounts = PancakeSwapRouter.swapExactETHForTokens{
                value: angelAccountScore
            }(0, path, owner(), block.timestamp);
            uint256 bnbAmount = amounts[0];
            uint256 tokenAmount = amounts[1];

            devilAccountScore += tokenAmount;
            angelAccountScore -= bnbAmount;

            emit Winner(0);
        }

        nextSpinTimestamp += 1 days;
    }

    /// @notice Changes current keyHash
    /// @param newKeyHash bytes32 new hash value
    function changeKeyHash(bytes32 newKeyHash) external onlyOwner {
        keyHash = newKeyHash;
    }

    /// @notice Changes current link fee amount
    /// @dev Perhaps chainlink will change this value in the future, so we should change it here also
    /// @param newFee uint256 new fee amount
    function changeLINKFee(uint256 newFee) external onlyOwner {
        fee = newFee;
    }

    /// @notice Withdraws ERC20 Tokens from contract
    /// @param tokenAddress ERC20 token address
    /// @param to to whom it will be transfered
    /// @param amount amount to be transfered
    function withdrawERC20Token(
        address tokenAddress,
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20(tokenAddress).transfer(to, amount);
    }

    function calculateOutputAmout(uint256 amountIn, bool defuctFee)
        public
        view
        returns (uint256)
    {
        if (!defuctFee) {
            return amountIn;
        } else {
            return _calculateFees(amountIn)[0];
        }
    }

    receive() external payable {}
}
