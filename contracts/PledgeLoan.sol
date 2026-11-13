// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAccessRegistry} from "./interfaces/IAccessRegistry.sol";

/// @title PledgeLoan
/// @notice 质押成交。法币在线下交付，合约不收手续费，也不留 USDT。
///         deliver 由质押方调用，把整笔 USDT 从质押方钱包转给承接方。
///         repay 由承接方调用，把同样数量的 USDT 还给质押方，这单结束。
///         前 7 天免息，之后按本金每天 0.1% 计息，计息天数不超过约定期限减 7 天。
///         利息只记在事件里，给线下的法币结算看。链上归还的是本金。
contract PledgeLoan is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant FREE_DAYS = 7;
    /// @notice 0.1% = 10 / 10000。
    uint256 public constant DAILY_BPS = 10;
    uint256 public constant BPS = 10_000;

    IAccessRegistry public immutable registry;
    IERC20 public immutable usdt;

    struct Loan {
        address pledgor;
        address counterparty;
        uint256 principal;
        uint64 startedAt;
        uint32 termDays;
        bool repaid;
    }

    uint256 public loanCount;
    mapping(uint256 loanId => Loan) private _loans;
    mapping(bytes32 orderKey => uint256 loanId) private _loanByOrder;

    error ZeroAddress();
    error SameParticipant();
    error NotWhitelisted();
    error BadTerm();
    error BadAmount();
    error BadOrder();
    error OrderUsed();
    error UnknownLoan();
    error NotCounterparty();
    error AlreadyRepaid();

    event Delivered(
        uint256 indexed loanId,
        address indexed pledgor,
        address indexed counterparty,
        uint256 principal,
        uint32 termDays,
        bytes32 orderKey
    );
    event Repaid(
        uint256 indexed loanId,
        address indexed pledgor,
        address indexed counterparty,
        uint256 principal,
        uint256 interest
    );

    constructor(address registry_, address usdt_) {
        if (registry_ == address(0) || usdt_ == address(0)) revert ZeroAddress();
        registry = IAccessRegistry(registry_);
        usdt = IERC20(usdt_);
    }

    /// @notice 质押方把 USDT 打给承接方。orderId 与后台订单号一致，只能用一次。
    function deliver(address counterparty, uint256 principal, uint32 termDays, string calldata orderId)
        external
        nonReentrant
        returns (uint256 loanId)
    {
        address pledgor = msg.sender;
        if (counterparty == address(0)) revert ZeroAddress();
        if (counterparty == pledgor) revert SameParticipant();
        if (principal == 0) revert BadAmount();
        if (!_allowedTerm(termDays)) revert BadTerm();
        if (!registry.isWhitelisted(pledgor) || !registry.isWhitelisted(counterparty)) revert NotWhitelisted();
        bytes32 key = orderKey(orderId);
        if (_loanByOrder[key] != 0) revert OrderUsed();

        loanId = ++loanCount;
        _loanByOrder[key] = loanId;
        _loans[loanId] = Loan({
            pledgor: pledgor,
            counterparty: counterparty,
            principal: principal,
            startedAt: uint64(block.timestamp),
            termDays: termDays,
            repaid: false
        });
        usdt.safeTransferFrom(pledgor, counterparty, principal);
        emit Delivered(loanId, pledgor, counterparty, principal, termDays, key);
    }

    /// @notice 承接方把本金 USDT 还给质押方。利息写进事件，不从本金里扣。
    function repay(uint256 loanId) external nonReentrant {
        Loan storage loan = _loans[loanId];
        if (loan.pledgor == address(0)) revert UnknownLoan();
        if (loan.repaid) revert AlreadyRepaid();
        if (msg.sender != loan.counterparty) revert NotCounterparty();
        loan.repaid = true;
        uint256 interest = interestDue(loan.principal, loan.startedAt, loan.termDays, block.timestamp);
        usdt.safeTransferFrom(msg.sender, loan.pledgor, loan.principal);
        emit Repaid(loanId, loan.pledgor, loan.counterparty, loan.principal, interest);
    }

    function interestDue(uint256 principal, uint64 startedAt, uint32 termDays, uint256 nowTs)
        public
        pure
        returns (uint256)
    {
        if (principal == 0 || nowTs <= startedAt) return 0;
        uint256 elapsed = (nowTs - startedAt) / 1 days;
        if (elapsed <= FREE_DAYS) return 0;
        uint256 billable = elapsed - FREE_DAYS;
        uint256 cap = termDays > FREE_DAYS ? uint256(termDays) - FREE_DAYS : 0;
        if (billable > cap) billable = cap;
        return principal * billable * DAILY_BPS / BPS;
    }

    function orderKey(string memory orderId) public pure returns (bytes32) {
        uint256 size = bytes(orderId).length;
        if (size == 0 || size > 32) revert BadOrder();
        return keccak256(bytes(orderId));
    }

    function loanIdByOrder(string calldata orderId) external view returns (uint256) {
        return _loanByOrder[orderKey(orderId)];
    }

    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return _loans[loanId];
    }

    function _allowedTerm(uint32 days_) private pure returns (bool) {
        return days_ == 7 || days_ == 14 || days_ == 21 || days_ == 28;
    }
}
