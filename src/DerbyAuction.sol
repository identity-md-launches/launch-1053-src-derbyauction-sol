// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./SwarmDerby.sol";

interface ISwarmDerby {
    function currentDay() external view returns (uint256);
    function dayClosed(uint8 league, uint256 day) external view returns (bool);
    function board(uint8 league, uint256 day) external view returns (address[] memory, uint256[] memory);
}

interface IAuctionTokenBalance {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Daily Theme Day auctions. Only the immutable derby's arcade board receives bonuses.
contract DerbyAuction {
    uint256 public constant MIN_BID = 2e18;
    uint256 public constant MIN_INCREMENT_BPS = 500;
    uint256 public constant CLOSE_OFFSET = 64800;
    uint256 public constant ANTI_SNIPE = 300;
    /// @notice Anti-snipe extensions stop one hour after the regular close (19:00 UTC), so the
    ///         build buffer and the owner's veto window stay at least five hours.
    uint256 public constant MAX_EXTENSION = 3600;
    uint256 public constant MAX_BUILD_FEE = 1e18;
    uint256 public constant RECLAIM_AFTER = 7 days;
    uint256 public constant TIP_BPS = 50;

    struct Answers {
        string creature;
        uint8 vibe;
        uint8 stadium;
        uint8 weather;
        string title;
        string shoutout;
    }

    struct Auction {
        address leader;
        uint256 amount;
        uint256 end;
        bool settled;
        bool vetoed;
        bool paid;
        uint256 bonus;
    }

    IERC20 public immutable imd;
    ISwarmDerby public immutable derby;
    address public owner;
    address public pendingOwner;
    address public studio;
    uint256 public buildFee;
    uint256 public carry;
    mapping(address => uint256) public refunds;
    /// @notice Historical carry included at settlement, never refundable to the bidder.
    mapping(uint256 => uint256) public carryIn;
    mapping(uint256 => Auction) internal _auctions;
    mapping(uint256 => Answers) internal _answers;
    bool private _entered;

    event Bid(
        uint256 indexed day,
        address indexed bidder,
        uint256 amount,
        uint256 end,
        string creature,
        uint8 vibe,
        uint8 stadium,
        uint8 weather,
        string title,
        string shoutout
    );
    event Settled(uint256 indexed day, address indexed winner, uint256 amount, uint256 fee, uint256 bonus);
    event Vetoed(uint256 indexed day, address indexed winner, uint256 refunded);
    /// @param amounts Actual receipts; zero if that winner's transfer failed.
    /// @param carried This day's unfilled shares, failed sends and rounding dust.
    event BonusPaid(
        uint256 indexed day, address[] winners, uint256[] amounts, address payer, uint256 tip, uint256 carried
    );
    event Reclaimed(uint256 indexed day, address indexed winner, uint256 amount);
    event RefundCredited(address indexed bidder, uint256 amount);
    event RefundWithdrawn(address indexed bidder, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event StudioSet(address indexed studio);
    event BuildFeeSet(uint256 fee);

    error NotOwner();
    error ZeroAddress();
    error BadFee();
    error BadDay();
    error BidClosed();
    error BidTooLow();
    error BadAnswers();
    error WrongStatus();
    error TooEarly();
    error DayNotClosed();
    error NoRefund();
    error NotAContract();
    error TransferFailed();
    error ReentrantCall();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    /// @dev No calls or code checks here: the launch harness uses an empty chain.
    constructor(address owner_, IERC20 imd_, ISwarmDerby derby_, address studio_, uint256 buildFee_) {
        if (
            owner_ == address(0) || address(imd_) == address(0) || address(derby_) == address(0)
                || studio_ == address(0)
        ) revert ZeroAddress();
        if (buildFee_ > MAX_BUILD_FEE) revert BadFee();
        owner = owner_;
        imd = imd_;
        derby = derby_;
        studio = studio_;
        buildFee = buildFee_;
        emit OwnershipTransferred(address(0), owner_);
    }

    function openDay() external view returns (uint256) {
        // The first partial UTC day has no representable two-days-prior start.
        if (block.timestamp < CLOSE_OFFSET) return 1;
        return (block.timestamp - CLOSE_OFFSET) / 1 days + 2;
    }

    function auction(uint256 day)
        external
        view
        returns (address leader, uint256 amount, uint256 end, bool settled, bool vetoed, bool paid, uint256 bonus)
    {
        Auction storage a = _auctions[day];
        return (a.leader, a.amount, _end(day), a.settled, a.vetoed, a.paid, a.bonus);
    }

    function answers(uint256 day) external view returns (Answers memory) {
        return _answers[day];
    }

    /// @notice The next whole-wei bid that is at least 5% higher (rounded up).
    function minNextBid(uint256 day) public view returns (uint256) {
        uint256 lead = _auctions[day].amount;
        uint256 increment = _bps(lead, MIN_INCREMENT_BPS);
        if (mulmod(lead, MIN_INCREMENT_BPS, 10_000) != 0) ++increment;
        uint256 next = lead + increment;
        return next < MIN_BID ? MIN_BID : next;
    }

    function bid(uint256 day, uint256 amount, Answers calldata a) external nonReentrant {
        uint256 end = _end(day);
        Auction storage sale = _auctions[day];
        if (sale.settled || block.timestamp < (day - 2) * 1 days + CLOSE_OFFSET || block.timestamp >= end) {
            revert BidClosed();
        }
        if (amount < minNextBid(day)) revert BidTooLow();
        _checkAnswers(a);
        address previous = sale.leader;
        uint256 previousAmount = sale.amount;
        if (end - block.timestamp < ANTI_SNIPE) {
            end = block.timestamp + ANTI_SNIPE;
            uint256 latest = (day - 1) * 1 days + CLOSE_OFFSET + MAX_EXTENSION;
            if (end > latest) end = latest;
        }
        sale.leader = msg.sender;
        sale.amount = amount;
        sale.end = end;
        _answers[day] = a;

        _pull(msg.sender, amount);
        _refund(previous, previousAmount);
        emit Bid(day, msg.sender, amount, end, a.creature, a.vibe, a.stadium, a.weather, a.title, a.shoutout);
    }

    function settle(uint256 day) external nonReentrant {
        Auction storage a = _auctions[day];
        if (a.settled) revert WrongStatus();
        if (block.timestamp < _end(day)) revert TooEarly();
        a.settled = true;
        uint256 fee;
        if (a.leader != address(0)) {
            fee = buildFee < a.amount ? buildFee : a.amount;
            carryIn[day] = carry;
            a.bonus = a.amount - fee + carry;
            carry = 0;
            _send(studio, fee);
        }
        emit Settled(day, a.leader, a.amount, fee, a.bonus);
    }

    function veto(uint256 day) external onlyOwner nonReentrant {
        Auction storage a = _auctions[day];
        _checkRefundable(a);
        if (block.timestamp >= day * 1 days) revert BidClosed();
        a.vetoed = true;
        uint256 amount = _releaseBonus(day, a);
        _refund(a.leader, amount);
        emit Vetoed(day, a.leader, amount);
    }

    function payBonus(uint256 day) external nonReentrant {
        Auction storage a = _auctions[day];
        _checkRefundable(a);
        if (!derby.dayClosed(0, day)) revert DayNotClosed();
        a.paid = true;
        uint256 bonus = a.bonus;
        a.bonus = 0;
        (address[] memory board,) = derby.board(0, day);
        uint256 n = board.length < 3 ? board.length : 3;
        address[] memory winners = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 tip;
        uint256 paid;
        if (n > 0) {
            tip = _bps(bonus, TIP_BPS);
            paid = tip;
            uint16[3] memory shares = [uint16(6000), 2500, 1500];
            for (uint256 i; i < n; ++i) {
                winners[i] = board[i];
                amounts[i] = _bps(bonus - tip, shares[i]);
                paid += amounts[i];
            }
        }
        uint256 carried = bonus - paid;
        carry += carried;
        _send(msg.sender, tip);
        for (uint256 i; i < n; ++i) {
            if (!_trySend(winners[i], amounts[i])) {
                carry += amounts[i];
                carried += amounts[i];
                amounts[i] = 0;
            }
        }
        emit BonusPaid(day, winners, amounts, msg.sender, tip, carried);
    }

    /// @notice Anyone can return an unpaid, expired bonus to its original winner.
    function reclaim(uint256 day) external nonReentrant {
        Auction storage a = _auctions[day];
        _checkRefundable(a);
        if (block.timestamp <= (day + 1) * 1 days + RECLAIM_AFTER) revert TooEarly();
        a.paid = true; // terminal: a reclaimed bonus cannot also be paid or reclaimed again
        uint256 amount = _releaseBonus(day, a);
        _refund(a.leader, amount);
        emit Reclaimed(day, a.leader, amount);
    }

    function withdrawRefund() external nonReentrant {
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert NoRefund();
        refunds[msg.sender] = 0;
        _send(msg.sender, amount);
        emit RefundWithdrawn(msg.sender, amount);
    }

    function setStudio(address studio_) external onlyOwner {
        if (studio_ == address(0)) revert ZeroAddress();
        studio = studio_;
        emit StudioSet(studio_);
    }

    function setBuildFee(uint256 fee) external onlyOwner {
        if (fee > MAX_BUILD_FEE) revert BadFee();
        buildFee = fee;
        emit BuildFeeSet(fee);
    }

    /// @notice Setting zero cancels the pending handover; it does not renounce ownership.
    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function _end(uint256 day) internal view returns (uint256) {
        if (day < 2) revert BadDay();
        uint256 end = _auctions[day].end;
        return end == 0 ? (day - 1) * 1 days + CLOSE_OFFSET : end;
    }

    function _checkRefundable(Auction storage a) internal view {
        if (!a.settled || a.leader == address(0) || a.vetoed || a.paid || a.bonus == 0) revert WrongStatus();
    }

    function _releaseBonus(uint256 day, Auction storage a) internal returns (uint256 amount) {
        uint256 carried = carryIn[day];
        amount = a.bonus - carried;
        a.bonus = 0;
        carry += carried;
    }

    function _checkAnswers(Answers calldata a) internal pure {
        if (a.vibe > 3 || a.stadium > 5 || a.weather > 5) revert BadAnswers();
        _checkString(bytes(a.creature), 1, 24);
        _checkString(bytes(a.title), 1, 24);
        _checkString(bytes(a.shoutout), 0, 32);
    }

    function _checkString(bytes calldata s, uint256 min, uint256 max) internal pure {
        if (s.length < min || s.length > max) revert BadAnswers();
        for (uint256 i; i < s.length; ++i) {
            bytes1 c = s[i];
            if (c < 0x20 || c > 0x7e || c == 0x3c || c == 0x3e || c == 0x22 || c == 0x5c) revert BadAnswers();
        }
    }

    /// @dev Exact floor(amount * bps / 10000), without an overflowing intermediate product.
    function _bps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return amount / 10_000 * bps + (amount % 10_000) * bps / 10_000;
    }

    function _refund(address bidder, uint256 amount) internal {
        if (!_trySend(bidder, amount)) {
            refunds[bidder] += amount;
            emit RefundCredited(bidder, amount);
        }
    }

    function _pull(address from, uint256 amount) internal {
        if (address(imd).code.length == 0) revert NotAContract();
        uint256 before = IAuctionTokenBalance(address(imd)).balanceOf(address(this));
        (bool ok, bytes memory data) =
            address(imd).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || !_accepted(data)) revert TransferFailed();
        uint256 afterBalance = IAuctionTokenBalance(address(imd)).balanceOf(address(this));
        if (afterBalance < before || afterBalance - before != amount) revert TransferFailed();
    }

    function _send(address to, uint256 amount) internal {
        if (!_trySend(to, amount)) revert TransferFailed();
    }

    function _trySend(address to, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        if (address(imd).code.length == 0) return false;
        (bool ok, bytes memory data) = address(imd).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && _accepted(data);
    }

    function _accepted(bytes memory data) internal pure returns (bool) {
        if (data.length == 0) return true;
        if (data.length != 32) return false;
        // A malformed boolean is a failed send, not a revert that blocks other recipients.
        uint256 value;
        assembly ("memory-safe") { value := mload(add(data, 32)) }
        return value == 1;
    }
}
