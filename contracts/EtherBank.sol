pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./EtherDollar.sol";
import "./Liquidator.sol";


/**
 * @title EtherBank contract.
 */
contract EtherBank {
    using SafeMath for uint256;

    uint256 public lastLoanId;
    uint256 public etherPrice;
    uint256 public collateralRatio;
    uint256 public liquidationDuration;
    address public oraclesAddr;
    address public liquidatorAddr;
    address public etherDollarAddr;

    EtherDollar internal token;
    Liquidator internal liquidator;

    uint256 constant internal PRECISION_POINT = 10 ** 3;
    uint256 constant internal ETHER_TO_WEI = 10 ** 18;
    uint256 constant internal MAX_LOAN = 10000 * 100;
    uint256 constant internal COLLATERAL_MULTIPLIER = 2;

    enum Types {
        ETHER_PRICE,
        COLLATERAL_RATIO,
        LIQUIDATION_DURATION
    }

    enum LoanState {
        UNDEFINED,
        ACTIVE,
        UNDER_LIQUIDATION,
        LIQUIDATED,
        SETTLED
    }

    struct Loan {
        address payable recipient;
        uint256 collateral;
        uint256 amount;
        LoanState state;
    }

    mapping(uint256 => Loan) public loans;

    event LoanGot(address indexed recipient, uint256 indexed loanId, uint256 collateral, uint256 amount);
    event LoanSettled(address recipient, uint256 indexed loanId, uint256 collateral, uint256 amount);
    event CollateralIncreased(address indexed recipient, uint256 indexed loanId, uint256 collateral);
    event CollateralDecreased(address indexed recipient, uint256 indexed loanId, uint256 collateral);

    string private constant INVALID_AMOUNT = "INVALID_AMOUNT";
    string private constant INITIALIZED_BEFORE = "INITIALIZED_BEFORE";
    string private constant SUFFICIENT_COLLATERAL = "SUFFICIENT_COLLATERAL";
    string private constant INSUFFICIENT_COLLATERAL = "INSUFFICIENT_COLLATERAL";
    string private constant INSUFFICIENT_ALLOWANCE = "INSUFFICIENT_ALLOWANCE";
    string private constant ONLY_LOAN_OWNER = "ONLY_LOAN_OWNER";
    string private constant ONLY_LIQUIDATOR = "ONLY_LIQUIDATOR";
    string private constant ONLY_ORACLES = "ONLY_ORACLE";
    string private constant INVALID_LOAN_STATE = "INVALID_LOAN_STATE";
    string private constant EXCEEDED_MAX_LOAN = "EXCEEDED_MAX_LOAN";

    constructor(address _tokenAddr)
        public
    {
        token = EtherDollar(_tokenAddr);
        etherDollarAddr = _tokenAddr;
        collateralRatio = 1500; // = 1.5 * PRECISION_POINT
        liquidationDuration = 7200; // = 2 hours
    }

    /**
     * @notice Gives out as much as half the maximum loan you can possibly receive from the smart contract
     * @dev Fallback function.
     */
    function() external
      payable
    {
        if (msg.value > 0) {
            uint256 amount = msg.value.mul(PRECISION_POINT).mul(etherPrice).div(collateralRatio).div(ETHER_TO_WEI).div(COLLATERAL_MULTIPLIER);
            getLoan(amount);
        }
    }

    /**
     * @notice Set Liquidator's address.
     * @param _liquidatorAddr The Liquidator's contract address.
     */
    function setLiquidator(address _liquidatorAddr)
        external
    {
        require(liquidatorAddr == address(0), INITIALIZED_BEFORE);

        liquidatorAddr = _liquidatorAddr;
        liquidator = Liquidator(_liquidatorAddr);
    }

    /**
     * @notice Set oracle's address.
     * @param _oraclesAddr The oracle's contract address.
     */
    function setOracle(address _oraclesAddr)
        external
    {
        require (oraclesAddr == address(0), INITIALIZED_BEFORE);

        oraclesAddr = _oraclesAddr;
    }

    /**
     * @notice Set important varibales by oracles.
     * @param _type Type of the variable.
     * @param value Amount of the variable.
     */
    function setVariable(uint8 _type, uint256 value)
        external
        onlyOracles
        throwIfEqualToZero(value)
    {
        if (uint8(Types.ETHER_PRICE) == _type) {
            etherPrice = value;
        } else if (uint8(Types.COLLATERAL_RATIO) == _type) {
            collateralRatio = value;
        } else if (uint8(Types.LIQUIDATION_DURATION) == _type) {
            liquidationDuration = value;
        }
    }

    /**
     * @notice Deposit ether to borrow ether dollar.
     * @param amount The amount of requsted loan in ether dollar.
     */
    function getLoan(uint256 amount)
        public
        payable
        throwIfEqualToZero(amount)
        throwIfEqualToZero(msg.value)
    {
        require (amount <= MAX_LOAN, EXCEEDED_MAX_LOAN);
        require (minCollateral(amount) <= msg.value, INSUFFICIENT_COLLATERAL);
        uint256 loanId = ++lastLoanId;
        loans[loanId].recipient = msg.sender;
        loans[loanId].collateral = msg.value;
        loans[loanId].amount = amount;
        loans[loanId].state = LoanState.ACTIVE;
        emit LoanGot(msg.sender, loanId, msg.value, amount);
        token.mint(msg.sender, amount);
    }

    /**
     * @notice Increase the loan's collateral.
     * @param loanId The loan id.
     */
    function increaseCollateral(uint256 loanId)
        external
        payable
        throwIfEqualToZero(msg.value)
        checkLoanState(loanId, LoanState.ACTIVE)
    {
        loans[loanId].collateral = loans[loanId].collateral.add(msg.value);
        emit CollateralIncreased(msg.sender, loanId, msg.value);
    }

    /**
     * @notice Pay back extera collateral.
     * @param loanId The loan id.
     * @param amount The amout of extera colatral.
     */
    function decreaseCollateral(uint256 loanId, uint256 amount, address payable)
        external
        throwIfEqualToZero(amount)
        onlyLoanOwner(loanId)
    {
        require(loans[loanId].state != LoanState.UNDER_LIQUIDATION, INVALID_LOAN_STATE);
        require(minCollateral(loans[loanId].amount) <= loans[loanId].collateral.sub(amount), INSUFFICIENT_COLLATERAL);
        loans[loanId].collateral = loans[loanId].collateral.sub(amount);
        emit CollateralDecreased(msg.sender, loanId, amount);
        loans[loanId].recipient.transfer(amount);
    }

    /**
     * @notice pay ether dollars back to settle the loan.
     * @param loanId The loan id.
     * @param amount The ether dollar amount payed back.
     */
    function settleLoan(uint256 loanId, uint256 amount)
        external
        checkLoanState(loanId, LoanState.ACTIVE)
        throwIfEqualToZero(amount)
    {
        require(amount <= loans[loanId].amount, INVALID_AMOUNT);
        require(token.transferFrom(msg.sender, address(this), amount), INSUFFICIENT_ALLOWANCE);
        uint256 payback = loans[loanId].collateral.mul(amount).div(loans[loanId].amount);
        token.burn(amount);
        loans[loanId].collateral = loans[loanId].collateral.sub(payback);
        loans[loanId].amount = loans[loanId].amount.sub(amount);
        if (loans[loanId].amount == 0) {
            loans[loanId].state = LoanState.SETTLED;
        }
        emit LoanSettled(loans[loanId].recipient, loanId, payback, amount);
        loans[loanId].recipient.transfer(payback);
    }

    /**
     * @notice Start liquidation process of the loan.
     * @param loanId The loan id.
     */
    function liquidate(uint256 loanId)
        external
        checkLoanState(loanId, LoanState.ACTIVE)
    {
        require (loans[loanId].collateral < minCollateral(loans[loanId].amount), SUFFICIENT_COLLATERAL);
        loans[loanId].state = LoanState.UNDER_LIQUIDATION;
        liquidator.startLiquidation(
            loanId,
            loans[loanId].collateral,
            loans[loanId].amount,
            liquidationDuration
        );
    }

    /**
     * @dev pay a part of the collateral to the auction's winner.
     * @param loanId The loan id.
     * @param collateral The bid of winner.
     * @param buyer The winner account.
     */
    function liquidated(uint256 loanId, uint256 collateral, address payable buyer)
        external
        onlyLiquidator
        checkLoanState(loanId, LoanState.UNDER_LIQUIDATION)
    {
        require (collateral <= loans[loanId].collateral, INVALID_AMOUNT);
        loans[loanId].collateral = loans[loanId].collateral.sub(collateral);
        loans[loanId].amount = 0;
        loans[loanId].state = LoanState.LIQUIDATED;
        buyer.transfer(collateral);
    }


    /**
     * @notice Minimum collateral in wei that is required for borrowing `amount` cents.
     * @param amount The amount of the loan in cents.
     */
    function minCollateral(uint256 amount)
        public
        view
        returns (uint256)
    {
        uint256 min = amount.mul(collateralRatio).mul(ETHER_TO_WEI).div(PRECISION_POINT).div(etherPrice);
        return min;
    }

    /**
     * @dev Throws if called by any account other than our Oracle.
     */
    modifier onlyOracles() {
        require(msg.sender == oraclesAddr, ONLY_ORACLES);
        _;
    }

    /**
     * @dev Throws if called by any account other than our Liquidator.
     */
    modifier onlyLiquidator() {
        require(msg.sender == liquidatorAddr, ONLY_LIQUIDATOR);
        _;
    }

    /**
     * @dev Throws if the number is equal to zero.
     * @param number The number to validate.
     */
    modifier throwIfEqualToZero(uint number) {
        require(number != 0, INVALID_AMOUNT);
        _;
    }

    /**
     * @dev Throws if called by any account other than the owner of the loan.
     * @param loanId The loan id.
     */
    modifier onlyLoanOwner(uint256 loanId) {
        require(loans[loanId].recipient == msg.sender, ONLY_LOAN_OWNER);
        _;
    }

    /**
     * @dev Throws if state is not equal to needState.
     * @param loanId The id of the loan.
     * @param needState The state which needed.
     */
    modifier checkLoanState(uint256 loanId, LoanState needState) {
        require(loans[loanId].state == needState, INVALID_LOAN_STATE);
        _;
    }
}
