// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAccessRegistry} from "./interfaces/IAccessRegistry.sol";

/// @title OtcTrade
/// @notice OTC 撮合。买方要买的标的在链下交付。合约不托管 USDT。
///         付 U 的人确认一次即可。pay 从付 U 的人钱包直接转两笔：对方拿剩余，平台拿手续费。
///         收 U 的人不用签名。钱不进入本合约。
///         手续费默认 1%，超级管理员可改，最高 5%。开单时把当时的百分比锁进这一单。
///         本实现永久关闭升级。
contract OtcTrade is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice 默认手续费百分比。存储值为 0 时按这个算。
    uint256 public constant FEE_PERCENT = 1;
    /// @notice 超级管理员能设置的最高手续费百分比。
    uint256 public constant MAX_FEE_PERCENT = 5;
    /// @notice 手续费分母。分子是百分比，100 表示按百分数算。余数留给卖方。
    uint256 public constant FEE_DENOMINATOR = 100;
    /// @notice 白名单与权限合约（AccessRegistry 代理地址）。
    IAccessRegistry public registry;

    /// @notice 已打开的成交笔数（tradeId 从 1 起）。
    uint256 public tradeCount;

    enum TradeStatus {
        None,
        Opened,
        Completed,
        Cancelled,
        Deposited,
        Refunded
    }

    struct Trade {
        address buyer;
        address seller;
        uint256 usdtAmount;
        uint256 hkdAmount;
        bytes32 offchainOrderId;
        bytes32 tradeHash;
        uint64 openedAt;
        uint64 expiry;
        bool buyerConfirmed;
        bool sellerConfirmed;
        TradeStatus status;
    }

    mapping(uint256 tradeId => Trade) private _trades;

    /// @notice 结算使用的 USDT。只能由超级管理员设置一次。
    address public usdtToken;

    /// @notice 手续费收款地址。空地址表示使用超级管理员 owner()。
    address public feeRecipient;

    /// @notice 当前手续费百分比。0 表示仍用默认 1%。只能改成 1 到 5。
    ///         放在旧变量后面，避免升级时挪动已有存储。
    uint256 public feePercent;

    /// @notice 每笔成交在开单时锁定的手续费百分比。0 表示这单开在本规则之前，按 1% 结算。
    mapping(uint256 tradeId => uint256 percent) private _lockedFeePercent;

    /// @notice 上一版买卖合约。只用来按订单号读取已经记过的成交，不再从这里收款。
    OtcTrade public previousBook;

    /// @notice 本合约里按订单号找到的成交编号。订单号与后台一致，例如 S-261110-7702074f。
    mapping(bytes32 orderKey => uint256 tradeId) private _tradeByOrder;

    /// @notice 上一版合约里的成交编号。键同样是订单号的 keccak256。
    mapping(bytes32 orderKey => uint256 tradeId) private _linkedOrder;

    error EthRejected();
    error UpgradeCalldataDisabled();
    error RenounceDisabled();
    error ZeroAddress();
    error SameParticipant();
    error BuyerNotWhitelisted();
    error SellerNotWhitelisted();
    error ZeroAmount();
    error InvalidExpiry();
    error TradeNotFound();
    error TradeNotOpen();
    error TradeExpired();
    error HashMismatch();
    error AlreadyConfirmed();
    error NotTradeParty();
    error NotCancellable();
    error NotBuyer();
    error UsdtNotSet();
    error UsdtAlreadySet();
    error NotDeposited();
    error CustodyDisabled();
    error NotFullyConfirmed();
    error SettlementRequired();
    error UpgradeDisabled();
    error FeeRecipientIsContract();
    error FeePercentOutOfRange();
    error InvalidOrderId();
    error OrderAlreadyUsed();
    error PreviousBookMissing();
    error PreviousBookSet();

    event TradeOpened(
        uint256 indexed tradeId,
        address indexed buyer,
        address indexed seller,
        uint256 usdtAmount,
        uint256 hkdAmount,
        bytes32 offchainOrderId,
        bytes32 tradeHash,
        uint64 expiry
    );
    event TradeConfirmed(uint256 indexed tradeId, address indexed party, bytes32 tradeHash);
    event TradeCompleted(uint256 indexed tradeId, bytes32 tradeHash);
    event TradeCancelled(uint256 indexed tradeId, address indexed by);
    event TradeDeposited(uint256 indexed tradeId, address indexed buyer, uint256 amount);
    event TradeSettled(
        uint256 indexed tradeId, address indexed seller, address indexed feeWallet, uint256 sellerAmount, uint256 platformFee
    );
    event TradeRefunded(uint256 indexed tradeId, address indexed buyer, uint256 amount);
    event FeePercentUpdated(uint256 percent);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化代理：写入管理员与白名单合约地址。
    function initialize(address initialOwner, address registry_) external initializer {
        if (initialOwner == address(0) || registry_ == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        registry = IAccessRegistry(registry_);
    }

    /// @notice 更换逻辑合约。不能附带以太币，也不能附带额外调用。
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override {
        if (msg.value != 0) revert EthRejected();
        if (data.length != 0) revert UpgradeCalldataDisabled();
        super.upgradeToAndCall(newImplementation, data);
    }

    /// @notice 付款和拆分已经固定。超级管理员也不能再升级本合约。
    function _authorizeUpgrade(address) internal pure override {
        revert UpgradeDisabled();
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice 当前手续费收款地址。未单独设置时就是超级管理员。
    function feeWallet() public view returns (address) {
        if (feeRecipient == address(0)) return owner();
        return feeRecipient;
    }

    /// @notice 设置 USDT。只能设置一次。
    function setUsdt(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (usdtToken != address(0)) revert UsdtAlreadySet();
        usdtToken = token;
    }

    /// @notice 更换手续费地址。传入空地址则恢复为超级管理员。
    ///         不能设成本合约，否则手续费会转进来且没有取回函数。
    function setFeeRecipient(address wallet) external onlyOwner {
        if (wallet == address(this)) revert FeeRecipientIsContract();
        feeRecipient = wallet;
    }

    /// @notice 调整之后新开的单使用的手续费。只接受 1 到 5。已开的单不受影响。
    function setFeePercent(uint256 percent) external onlyOwner {
        if (percent < FEE_PERCENT || percent > MAX_FEE_PERCENT) revert FeePercentOutOfRange();
        feePercent = percent;
        emit FeePercentUpdated(percent);
    }

    /// @notice 现在新开一单会锁定的百分比。还没改过时是 1。
    function currentFeePercent() public view returns (uint256) {
        if (feePercent == 0) return FEE_PERCENT;
        return feePercent;
    }

    /// @notice 某一单实际结算用的百分比。开单时锁定；旧单没有锁，按 1。
    function tradeFeePercent(uint256 tradeId) public view returns (uint256) {
        if (_trades[tradeId].status == TradeStatus.None) revert TradeNotFound();
        uint256 locked = _lockedFeePercent[tradeId];
        if (locked == 0) return FEE_PERCENT;
        return locked;
    }

    /// @notice 按当前百分比预览一笔新金额怎么拆。已开的单要用 quoteTradeFee。
    function quoteFee(uint256 amount) public view returns (uint256 platformFee, uint256 sellerAmount) {
        return _split(amount, currentFeePercent());
    }

    /// @notice 按这一单开单时锁定的百分比拆分。后端核对时调用，结算时用同一结果。
    function quoteTradeFee(uint256 tradeId) public view returns (uint256 platformFee, uint256 sellerAmount) {
        Trade storage t = _trades[tradeId];
        if (t.status == TradeStatus.None) revert TradeNotFound();
        return _split(t.usdtAmount, tradeFeePercent(tradeId));
    }

    function _split(uint256 amount, uint256 percent) internal pure returns (uint256 platformFee, uint256 sellerAmount) {
        platformFee = (amount * percent) / FEE_DENOMINATOR;
        sellerAmount = amount - platformFee;
    }

    /// @notice 校验买方与卖方都在白名单（含管理员 / 超级管理员）。
    function requireWhitelistedPair(address buyer, address seller) public view {
        if (buyer == address(0) || seller == address(0)) revert ZeroAddress();
        if (buyer == seller) revert SameParticipant();
        if (!registry.isWhitelisted(buyer)) revert BuyerNotWhitelisted();
        if (!registry.isWhitelisted(seller)) revert SellerNotWhitelisted();
    }

    /// @notice 只读探测：分别返回买方、卖方是否在白名单（不 revert）。
    function checkWhitelistedPair(
        address buyer,
        address seller
    ) external view returns (bool buyerOk, bool sellerOk) {
        if (buyer != address(0)) {
            buyerOk = registry.isWhitelisted(buyer);
        }
        if (seller != address(0)) {
            sellerOk = registry.isWhitelisted(seller);
        }
    }

    /// @notice 计算成交内容哈希（与开单时锁定的一致）。确认时必须提交相同值。
    function computeTradeHash(
        address buyer,
        address seller,
        uint256 usdtAmount,
        uint256 hkdAmount,
        bytes32 offchainOrderId
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid, address(this), buyer, seller, usdtAmount, hkdAmount, offchainOrderId
            )
        );
    }

    /// @notice 平台打开一笔成交：锁定双方与金额。不托管资金。
    /// @param expiry 双方须在此时间前确认；0 表示不设过期。
    function openTrade(
        address buyer,
        address seller,
        uint256 usdtAmount,
        uint256 hkdAmount,
        bytes32 offchainOrderId,
        uint64 expiry
    ) external onlyOwner returns (uint256 tradeId, bytes32 tradeHash) {
        requireWhitelistedPair(buyer, seller);
        if (usdtAmount == 0 || hkdAmount == 0) revert ZeroAmount();
        if (expiry != 0 && expiry <= block.timestamp) revert InvalidExpiry();

        tradeHash = computeTradeHash(buyer, seller, usdtAmount, hkdAmount, offchainOrderId);
        tradeId = ++tradeCount;

        _trades[tradeId] = Trade({
            buyer: buyer,
            seller: seller,
            usdtAmount: usdtAmount,
            hkdAmount: hkdAmount,
            offchainOrderId: offchainOrderId,
            tradeHash: tradeHash,
            openedAt: uint64(block.timestamp),
            expiry: expiry,
            buyerConfirmed: false,
            sellerConfirmed: false,
            status: TradeStatus.Opened
        });
        _lockedFeePercent[tradeId] = currentFeePercent();

        emit TradeOpened(
            tradeId, buyer, seller, usdtAmount, hkdAmount, offchainOrderId, tradeHash, expiry
        );
    }

    /// @notice 买方或卖方确认本笔成交条款。确认本身不转币。
    function confirmTrade(uint256 tradeId, bytes32 tradeHash) external {
        Trade storage t = _trades[tradeId];
        if (t.status == TradeStatus.None) revert TradeNotFound();
        if (t.status != TradeStatus.Opened) revert TradeNotOpen();
        if (t.expiry != 0 && block.timestamp > t.expiry) revert TradeExpired();
        if (tradeHash != t.tradeHash) revert HashMismatch();

        if (msg.sender == t.buyer) {
            if (!registry.isWhitelisted(msg.sender)) revert BuyerNotWhitelisted();
            if (t.buyerConfirmed) revert AlreadyConfirmed();
            t.buyerConfirmed = true;
        } else if (msg.sender == t.seller) {
            if (!registry.isWhitelisted(msg.sender)) revert SellerNotWhitelisted();
            if (t.sellerConfirmed) revert AlreadyConfirmed();
            t.sellerConfirmed = true;
        } else {
            revert NotTradeParty();
        }

        emit TradeConfirmed(tradeId, msg.sender, tradeHash);
    }

    /// @notice 不再收币托管。调用会直接拒绝。
    function deposit(uint256) external pure {
        revert CustodyDisabled();
    }

    /// @notice 付 U 的人已经确认时，按开单锁定的百分比从他的钱包直接转两笔。谁都可以调用。
    ///         收 U 的人不用确认。代币不进入本合约。
    function settle(uint256 tradeId) external nonReentrant {
        Trade storage t = _trades[tradeId];
        if (t.status != TradeStatus.Opened) revert TradeNotOpen();
        if (!t.buyerConfirmed) revert NotFullyConfirmed();
        if (usdtToken == address(0)) revert UsdtNotSet();
        if (t.expiry != 0 && block.timestamp > t.expiry) revert TradeExpired();
        if (!registry.isWhitelisted(t.buyer)) revert BuyerNotWhitelisted();

        (uint256 platformFee, uint256 sellerAmount) = _split(t.usdtAmount, tradeFeePercent(tradeId));
        address wallet = feeWallet();
        if (wallet == address(this)) revert FeeRecipientIsContract();
        t.status = TradeStatus.Completed;

        IERC20 token = IERC20(usdtToken);
        if (sellerAmount != 0) token.safeTransferFrom(t.buyer, t.seller, sellerAmount);
        if (platformFee != 0) token.safeTransferFrom(t.buyer, wallet, platformFee);
        emit TradeSettled(tradeId, t.seller, wallet, sellerAmount, platformFee);
        emit TradeCompleted(tradeId, t.tradeHash);
    }

    /// @notice 记下上一版合约。只能设置一次。
    function setPreviousBook(address book) external onlyOwner {
        if (address(previousBook) != address(0)) revert PreviousBookSet();
        if (book == address(0) || book == address(this)) revert ZeroAddress();
        previousBook = OtcTrade(book);
    }

    /// @notice 把后台订单号对到上一版合约里已经付过的那一笔。不转币。
    function linkOrder(string calldata orderId, uint256 previousTradeId) external onlyOwner {
        if (address(previousBook) == address(0)) revert PreviousBookMissing();
        bytes32 key = _orderKey(orderId);
        if (_tradeByOrder[key] != 0 || _linkedOrder[key] != 0) revert OrderAlreadyUsed();
        (,,,, bytes32 offchainOrderId,,,,,,) = previousBook.getTrade(previousTradeId);
        if (offchainOrderId != key) revert HashMismatch();
        _linkedOrder[key] = previousTradeId;
    }

    /// @notice 付 U 的人确认一次。从调用者钱包转出整笔：99% 给收 U 的人，1% 给平台。
    /// @param orderId 后台订单号，例如 S-261110-7702074f。
    function pay(
        address receiver,
        uint256 usdtAmount,
        uint256 hkdAmount,
        string calldata orderId
    ) external nonReentrant returns (uint256 tradeId, bytes32 tradeHash) {
        address payer = msg.sender;
        requireWhitelistedPair(payer, receiver);
        if (usdtAmount == 0 || hkdAmount == 0) revert ZeroAmount();
        if (usdtToken == address(0)) revert UsdtNotSet();
        address wallet = feeWallet();
        if (wallet == address(this)) revert FeeRecipientIsContract();

        bytes32 offchainOrderId = _orderKey(orderId);
        if (_tradeByOrder[offchainOrderId] != 0 || _linkedOrder[offchainOrderId] != 0) revert OrderAlreadyUsed();

        tradeHash = computeTradeHash(payer, receiver, usdtAmount, hkdAmount, offchainOrderId);
        tradeId = ++tradeCount;
        _tradeByOrder[offchainOrderId] = tradeId;
        _trades[tradeId] = Trade({
            buyer: payer,
            seller: receiver,
            usdtAmount: usdtAmount,
            hkdAmount: hkdAmount,
            offchainOrderId: offchainOrderId,
            tradeHash: tradeHash,
            openedAt: uint64(block.timestamp),
            expiry: 0,
            buyerConfirmed: true,
            sellerConfirmed: false,
            status: TradeStatus.Completed
        });
        _lockedFeePercent[tradeId] = currentFeePercent();

        (uint256 platformFee, uint256 sellerAmount) = _split(usdtAmount, currentFeePercent());
        IERC20 token = IERC20(usdtToken);
        if (sellerAmount != 0) token.safeTransferFrom(payer, receiver, sellerAmount);
        if (platformFee != 0) token.safeTransferFrom(payer, wallet, platformFee);

        emit TradeOpened(tradeId, payer, receiver, usdtAmount, hkdAmount, offchainOrderId, tradeHash, 0);
        emit TradeConfirmed(tradeId, payer, tradeHash);
        emit TradeSettled(tradeId, receiver, wallet, sellerAmount, platformFee);
        emit TradeCompleted(tradeId, tradeHash);
    }

    /// @notice 不再托管，因此没有可退的余额。调用会直接拒绝。
    function refund(uint256) external pure {
        revert CustodyDisabled();
    }

    /// @notice 取消还没结算的成交。钱仍在付 U 的人钱包里。
    function cancelTrade(uint256 tradeId) external {
        Trade storage t = _trades[tradeId];
        if (t.status == TradeStatus.None) revert TradeNotFound();
        if (t.status != TradeStatus.Opened) revert NotCancellable();

        bool expired = t.expiry != 0 && block.timestamp > t.expiry;
        bool party = msg.sender == t.buyer || msg.sender == t.seller || msg.sender == owner();
        if (!expired && !party) revert NotTradeParty();

        t.status = TradeStatus.Cancelled;
        emit TradeCancelled(tradeId, msg.sender);
    }

    /// @notice 按成交编号读取一笔成交的全部字段。
    function getTrade(uint256 tradeId)
        public
        view
        returns (
            address buyer,
            address seller,
            uint256 usdtAmount,
            uint256 hkdAmount,
            bytes32 offchainOrderId,
            bytes32 tradeHash,
            uint64 openedAt,
            uint64 expiry,
            bool buyerConfirmed,
            bool sellerConfirmed,
            TradeStatus status
        )
    {
        Trade storage t = _trades[tradeId];
        if (t.status == TradeStatus.None) revert TradeNotFound();
        return (
            t.buyer,
            t.seller,
            t.usdtAmount,
            t.hkdAmount,
            t.offchainOrderId,
            t.tradeHash,
            t.openedAt,
            t.expiry,
            t.buyerConfirmed,
            t.sellerConfirmed,
            t.status
        );
    }

    /// @notice 按后台订单号读取成交。订单号与数据库一致，例如 S-261110-7702074f。
    function getTrade(string calldata orderId)
        external
        view
        returns (
            address buyer,
            address seller,
            uint256 usdtAmount,
            uint256 hkdAmount,
            bytes32 offchainOrderId,
            bytes32 tradeHash,
            uint64 openedAt,
            uint64 expiry,
            bool buyerConfirmed,
            bool sellerConfirmed,
            TradeStatus status
        )
    {
        bytes32 key = _orderKey(orderId);
        uint256 tradeId = _tradeByOrder[key];
        if (tradeId != 0) return getTrade(tradeId);
        uint256 linked = _linkedOrder[key];
        if (linked == 0 || address(previousBook) == address(0)) revert TradeNotFound();
        return previousBook.getTrade(linked);
    }

    /// @notice 后台订单号的键。格式是 S- 或 B-，加 6 位日期，加 8 位小写十六进制。
    function _orderKey(string calldata orderId) internal pure returns (bytes32) {
        bytes memory raw = bytes(orderId);
        if (raw.length != 17) revert InvalidOrderId();
        if (raw[0] != "S" && raw[0] != "B") revert InvalidOrderId();
        if (raw[1] != "-" || raw[8] != "-") revert InvalidOrderId();
        for (uint256 i = 2; i < 8; i++) {
            if (raw[i] < "0" || raw[i] > "9") revert InvalidOrderId();
        }
        for (uint256 i = 9; i < 17; i++) {
            bytes1 c = raw[i];
            bool digit = c >= "0" && c <= "9";
            bool hexLower = c >= "a" && c <= "f";
            if (!digit && !hexLower) revert InvalidOrderId();
        }
        return keccak256(raw);
    }
}
