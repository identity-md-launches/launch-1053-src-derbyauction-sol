// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DerbyOdds} from "./DerbyOdds.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 arbBlockNum) external view returns (bytes32);
}

/// @title SwarmDerby
/// @notice One-button batting cage on Robinhood Chain, paid in IMD, in two leagues:
///
///  ARCADE (0)  people playing the game page. Max 20 swings per wallet per UTC day.
///              Ranked by each player's LONGEST homer of the day.
///  AGENT  (1)  bots and AI agents playing straight against the contract, no cap.
///              Ranked by TOTAL homer feet for the day.
///
///  Each league has its own turns, pot, slam vault, scoreboard and daily settlement, so
///  agent volume never dilutes the arcade prize. On-chain a script and a person look the
///  same: the cap makes out-spending humans expensive, it does not make it impossible.
///
///  Turns:   1 turn for 0.15 IMD or a 5-turn pack for 0.5 IMD (owner-adjustable). Every
///           purchase is split 40% burned, 45% to that league's pot, 10% to its slam vault,
///           5% ops (funds the IMD oracle schedules).
///  Swings:  swing(league, quality, velo, commit), commit = keccak256(abi.encode(salt, player)).
///           The roll uses the hash of a block REVEAL_DELAY blocks later; the player then calls
///           finalize(swingId, salt). The player can't know the future hash when committing,
///           the sequencer builds that block without knowing the salt, and an unrevealed swing
///           counts as a foul, so nobody can steer a roll and hiding a bad one never pays.
///  Slams:   a 550+ ft swing pays half of its league's vault instantly.
///  Daily:   the IMD swarm ranks each league with an oracle `log-rank` over one event:
///             ArcadeGain(player, gain)  emitted when a player beats their own best today;
///                                       gains sum to the longest homer, so a summed
///                                       ranking is a longest-homer ranking.
///             AgentFeet(player, feet)   every agent homer; sums to total feet.
///           Anyone submits a league's signed attestation to settleDay, earns 0.5% of that
///           payout, and the league's top 3 are paid 60 / 25 / 15 from 90% of its pot.
contract SwarmDerby {
    // ───────── constants ─────────
    IArbSys internal constant ARB_SYS = IArbSys(address(100));
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint8 public constant ARCADE = 0;
    uint8 public constant AGENT = 1;
    uint256 public constant ARCADE_DAILY_CAP = 20;

    uint256 public constant PACK_SIZE = 5;
    uint256 public constant BURN_BPS = 4000;
    uint256 public constant POT_BPS = 4500;
    uint256 public constant VAULT_BPS = 1000; // ops gets the remaining 500
    uint256 public constant SLAM_VAULT_SHARE_BPS = 5000;
    uint256 public constant PAYOUT_BPS = 9000; // share of a pot paid per settlement; 10% rolls over
    uint256 public constant SETTLE_TIP_BPS = 50;

    /// @notice L2 blocks between a swing and the block whose hash decides it (~0.5s at 100ms).
    uint256 public constant REVEAL_DELAY = 5;
    /// @notice After this many blocks past target (~24s), an unrevealed swing counts as a foul.
    uint256 public constant FINALIZE_WINDOW = 240;
    uint256 public constant BOARD_SIZE = 10;
    uint256 public constant ORACLE_TIMELOCK = 2 days;

    uint16 public constant MIN_PANEL = 5;
    uint16 public constant MIN_QUORUM = 4;
    uint8 internal constant ANSWER_ADDRESS_ARRAY = 4;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,"
        "bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,"
        "uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    // ───────── types ─────────
    enum Status { None, Committed, Final }

    struct Swing {
        address player;
        uint8 league;
        uint8 quality;
        uint8 velo;
        Status status;
        uint64 targetBlock;
        bytes32 commit;
    }

    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    struct OracleConfig {
        address signer;
        bytes32 arcadeQuestion;
        bytes32 agentQuestion;
    }

    // ───────── state ─────────
    IERC20 public immutable imd;
    address public owner;
    uint256 public singlePrice; // per turn
    uint256 public packPrice;   // per PACK_SIZE turns

    uint256[2] public pot;
    uint256[2] public vault;
    uint256 public opsBalance;
    mapping(uint8 => mapping(address => uint256)) public turns; // league => player => turns
    mapping(uint256 => mapping(address => uint256)) public arcadeSwings; // day => player => swings

    /// @notice Session keys: a throwaway key a player authorizes to swing on their turns
    ///         without wallet popups. It can only spend turns and reveal; every homer,
    ///         slam payout and leaderboard credit goes to the player.
    mapping(address => address) public sessionPlayer; // session key -> player
    mapping(address => address) public sessionOf;     // player -> session key

    /// @notice Live scoreboards. Arcade: each player's longest homer today. Agent: total
    ///         homer feet today. `board` keeps the day's top BOARD_SIZE, highest first.
    ///         A convenience view for the game page; payouts follow the IMD oracle.
    mapping(uint8 => mapping(uint256 => mapping(address => uint256))) public dayScore;
    mapping(uint8 => mapping(uint256 => address[])) internal _board;

    mapping(uint256 => Swing) public swings;
    uint256 public nextSwingId;

    OracleConfig public oracle;
    OracleConfig public pendingOracle;
    uint256 public pendingOracleAt;
    uint256[2] public lastSettledToBlock;
    mapping(bytes32 => bool) public usedRequest;

    // ───────── events ─────────
    event TurnsBought(address indexed player, uint8 indexed league, uint256 count, uint256 cost, uint256 burned);
    event SessionSet(address indexed player, address indexed session);
    event SwingCommitted(uint256 indexed swingId, address indexed player, uint8 league, uint8 quality, uint8 velo, uint64 targetBlock);
    event SwingResolved(uint256 indexed swingId, address indexed player, uint8 tier, uint16 feet);
    /// @notice Every homer, either league.
    event Dinger(address indexed player, uint8 indexed league, uint256 feet);
    /// @notice Arcade ranking event: emitted only when a player beats their own best today.
    ///         Summed per player over the day it equals their longest homer.
    event ArcadeGain(address indexed player, uint256 gain);
    /// @notice Agent ranking event: every agent homer. Summed per player it is total feet.
    event AgentFeet(address indexed player, uint256 feet);
    event GrandSlam(uint256 indexed swingId, address indexed player, uint8 league, uint16 feet, uint256 payout);
    event DaySettled(uint8 indexed league, bytes32 indexed requestId, uint64 fromBlock, uint64 toBlock,
        address[] winners, uint256[] amounts, address settler, uint256 tip);
    event OracleChangeQueued(address signer, bytes32 arcadeQuestion, bytes32 agentQuestion, uint256 effectiveAt);
    event OracleChanged(address signer, bytes32 arcadeQuestion, bytes32 agentQuestion);

    error NotOwner();
    error BadLeague();
    error NoTurns();
    error DailyCapReached();
    error BadQuality();
    error BadCommit();
    error BadSalt();
    error WrongStatus();
    error TooEarly();
    error NotExpired();
    error BadSession();
    error TransferFailed();
    error BadAttestation(string why);
    error Timelocked();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier validLeague(uint8 league) {
        if (league > AGENT) revert BadLeague();
        _;
    }

    /// @param owner_ admin address. Pass it explicitly: when IMD's launch factory deploys
    ///               this, msg.sender is the factory (use `$owner` in the launch request).
    constructor(
        address owner_,
        IERC20 imd_,
        uint256 singlePrice_,
        uint256 packPrice_,
        address oracleSigner_,
        bytes32 arcadeQuestion_,
        bytes32 agentQuestion_
    ) {
        imd = imd_;
        owner = owner_;
        singlePrice = singlePrice_;
        packPrice = packPrice_;
        oracle = OracleConfig(oracleSigner_, arcadeQuestion_, agentQuestion_);
        uint256 nowBlock = ARB_SYS.arbBlockNumber();
        lastSettledToBlock[ARCADE] = nowBlock;
        lastSettledToBlock[AGENT] = nowBlock;
        emit OracleChanged(oracleSigner_, arcadeQuestion_, agentQuestion_);
    }

    // ───────── turns ─────────

    /// @notice Buy single turns in a league at singlePrice each.
    function buyTurns(uint8 league, uint256 count) external validLeague(league) {
        _buy(league, count, count * singlePrice);
    }

    /// @notice Buy packs of PACK_SIZE turns in a league at packPrice each.
    function buyPacks(uint8 league, uint256 packs) external validLeague(league) {
        _buy(league, packs * PACK_SIZE, packs * packPrice);
    }

    function _buy(uint8 league, uint256 count, uint256 cost) internal {
        uint256 burned = (cost * BURN_BPS) / 10_000;
        uint256 toPot = (cost * POT_BPS) / 10_000;
        uint256 toVault = (cost * VAULT_BPS) / 10_000;

        turns[league][msg.sender] += count;
        pot[league] += toPot;
        vault[league] += toVault;
        opsBalance += cost - burned - toPot - toVault;

        _pull(msg.sender, cost);
        _send(DEAD, burned);
        emit TurnsBought(msg.sender, league, count, cost, burned);
    }

    // ───────── sessions ─────────

    /// @notice Authorize (or with address(0), revoke) a session key for msg.sender.
    function setSession(address session) external {
        address old = sessionOf[msg.sender];
        if (old != address(0)) delete sessionPlayer[old];
        if (session != address(0)) {
            if (session == msg.sender || sessionPlayer[session] != address(0) || sessionOf[session] != address(0)) {
                revert BadSession();
            }
            sessionPlayer[session] = msg.sender;
        }
        sessionOf[msg.sender] = session;
        emit SessionSet(msg.sender, session);
    }

    /// @notice The player a caller acts for: itself, or the player that authorized it.
    function playerOf(address caller) public view returns (address) {
        address p = sessionPlayer[caller];
        return p == address(0) ? caller : p;
    }

    // ───────── swings ─────────

    /// @notice The commit a player sends with a swing. Compute it off-chain (same encoding).
    function commitFor(bytes32 salt, address player) public pure returns (bytes32) {
        return keccak256(abi.encode(salt, player));
    }

    /// @notice Swings left today for an arcade player (the cap resets at 00:00 UTC).
    function arcadeSwingsLeft(address player) external view returns (uint256) {
        uint256 used = arcadeSwings[currentDay()][player];
        return used >= ARCADE_DAILY_CAP ? 0 : ARCADE_DAILY_CAP - used;
    }

    /// @param league  ARCADE or AGENT; spends a turn from that league.
    /// @param quality 0 for a miss, 1-100 for contact (from exit velo + timing).
    /// @param velo    exit-velo score 0-100; under DerbyOdds.POWER_LINE no bomb or slam is possible.
    /// @param commit  commitFor(salt, player) for a fresh random salt; ignored on a miss.
    ///                `player` is the account whose turns are spent (playerOf(msg.sender)).
    function swing(uint8 league, uint8 quality, uint8 velo, bytes32 commit)
        external
        validLeague(league)
        returns (uint256 swingId)
    {
        if (quality > 100 || velo > 100) revert BadQuality();
        address player = playerOf(msg.sender);
        if (turns[league][player] == 0) revert NoTurns();
        if (league == ARCADE) {
            uint256 day = currentDay();
            if (arcadeSwings[day][player] >= ARCADE_DAILY_CAP) revert DailyCapReached();
            arcadeSwings[day][player] += 1;
        }
        turns[league][player] -= 1;

        swingId = nextSwingId++;
        if (quality == 0) {
            swings[swingId] = Swing(player, league, 0, velo, Status.Final, 0, bytes32(0));
            emit SwingResolved(swingId, player, DerbyOdds.WHIFF, 0);
            return swingId;
        }
        if (commit == bytes32(0)) revert BadCommit();

        uint64 target = uint64(ARB_SYS.arbBlockNumber() + REVEAL_DELAY);
        swings[swingId] = Swing(player, league, quality, velo, Status.Committed, target, commit);
        emit SwingCommitted(swingId, player, league, quality, velo, target);
    }

    /// @notice Reveal the salt once the target block exists. Anyone holding the salt may call
    ///         it, but only the player has it. Too late and the swing counts as a foul.
    function finalize(uint256 swingId, bytes32 salt) external returns (uint8 tier, uint16 feet) {
        Swing storage s = swings[swingId];
        if (s.status != Status.Committed) revert WrongStatus();
        if (commitFor(salt, s.player) != s.commit) revert BadSalt();
        uint256 current = ARB_SYS.arbBlockNumber();
        if (current <= s.targetBlock) revert TooEarly();

        s.status = Status.Final;
        bytes32 bh;
        if (current - s.targetBlock <= FINALIZE_WINDOW) {
            try ARB_SYS.arbBlockHash(s.targetBlock) returns (bytes32 h) { bh = h; } catch {}
        }
        if (bh == bytes32(0)) {
            tier = DerbyOdds.FOUL;
        } else {
            (tier, feet) = DerbyOdds.roll(swingSeed(salt, bh), swingId, s.quality, s.velo);
        }

        if (tier >= DerbyOdds.HOMER) _recordDinger(s.league, s.player, feet);
        if (tier == DerbyOdds.SLAM) {
            uint256 payout = (vault[s.league] * SLAM_VAULT_SHARE_BPS) / 10_000;
            vault[s.league] -= payout;
            emit GrandSlam(swingId, s.player, s.league, feet, payout);
            _send(s.player, payout);
        }
        emit SwingResolved(swingId, s.player, tier, feet);
    }

    /// @notice Close out a swing nobody revealed in time. Counts as a foul.
    function expire(uint256 swingId) external {
        Swing storage s = swings[swingId];
        if (s.status != Status.Committed) revert WrongStatus();
        if (ARB_SYS.arbBlockNumber() <= uint256(s.targetBlock) + FINALIZE_WINDOW) revert NotExpired();
        s.status = Status.Final;
        emit SwingResolved(swingId, s.player, DerbyOdds.FOUL, 0);
    }

    function swingSeed(bytes32 salt, bytes32 targetHash) public pure returns (bytes32) {
        return keccak256(abi.encode(salt, targetHash));
    }

    /// @notice Preview the odds table for a quality (cumulative bps).
    function oddsFor(uint8 quality) external pure returns (uint256[5] memory) {
        return DerbyOdds.thresholds(quality);
    }

    // ───────── live scoreboards ─────────

    function currentDay() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice A league's top players for a day, highest first. Arcade scores are longest
    ///         homers; agent scores are total homer feet.
    function board(uint8 league, uint256 day) external view returns (address[] memory players, uint256[] memory scores) {
        players = _board[league][day];
        scores = new uint256[](players.length);
        for (uint256 i; i < players.length; ++i) scores[i] = dayScore[league][day][players[i]];
    }

    function _recordDinger(uint8 league, address player, uint256 feet) internal {
        emit Dinger(player, league, feet);
        uint256 day = currentDay();
        uint256 old = dayScore[league][day][player];
        uint256 score;
        if (league == ARCADE) {
            if (feet <= old) return; // not a new personal best today
            score = feet;
            emit ArcadeGain(player, feet - old);
        } else {
            score = old + feet;
            emit AgentFeet(player, feet);
        }
        dayScore[league][day][player] = score;
        _bump(league, day, player, score);
    }

    /// @dev Keep the day's board sorted, highest first. Ties keep the earlier score ahead.
    function _bump(uint8 league, uint256 day, address player, uint256 score) internal {
        address[] storage b = _board[league][day];
        mapping(address => uint256) storage sc = dayScore[league][day];
        uint256 n = b.length;
        uint256 i = n; // player's slot; n = not on the board
        for (uint256 k; k < n; ++k) {
            if (b[k] == player) { i = k; break; }
        }
        if (i == n) {
            if (n < BOARD_SIZE) {
                b.push(player);
            } else {
                if (score <= sc[b[n - 1]]) return;
                i = n - 1;
                b[i] = player;
            }
        }
        while (i > 0 && sc[b[i - 1]] < score) {
            b[i] = b[i - 1];
            b[i - 1] = player;
            --i;
        }
    }

    // ───────── daily settlement via IMD oracle ─────────

    /// @notice Pay a league's top 3 from the attested ranking: 60 / 25 / 15 of 90% of that
    ///         league's pot, after a 0.5% tip to the caller. Unfilled places roll over.
    function settleDay(uint8 league, Attestation calldata a, bytes calldata signature) external validLeague(league) {
        bytes32 question = league == ARCADE ? oracle.arcadeQuestion : oracle.agentQuestion;
        if (usedRequest[a.requestId]) revert BadAttestation("replayed");
        if (question == bytes32(0) || a.questionHash != question) revert BadAttestation("question");
        if (a.chainId != block.chainid) revert BadAttestation("chain");
        if (a.answerType != ANSWER_ADDRESS_ARRAY) revert BadAttestation("answerType");
        if (a.panelSize < MIN_PANEL || a.quorum < MIN_QUORUM || a.agreed < a.quorum) revert BadAttestation("consensus");
        if (block.timestamp > a.expiresAt) revert BadAttestation("expired");
        // Windows come from a relative {hours: 24} schedule, so consecutive days may overlap
        // by a few blocks if a run fires early. Only require forward progress.
        if (a.toBlock <= lastSettledToBlock[league] || a.toBlock < a.fromBlock || a.toBlock >= ARB_SYS.arbBlockNumber()) {
            revert BadAttestation("window");
        }
        if (_recover(_digest(a), signature) != oracle.signer) revert BadAttestation("signer");

        usedRequest[a.requestId] = true;
        lastSettledToBlock[league] = a.toBlock;

        address[] memory ranked = abi.decode(a.answer, (address[]));
        uint256 n = ranked.length < 3 ? ranked.length : 3;
        address[] memory winners = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 distributable = (pot[league] * PAYOUT_BPS) / 10_000;
        uint256 tip = (distributable * SETTLE_TIP_BPS) / 10_000;
        distributable -= tip;
        uint16[3] memory shares = [uint16(6000), 2500, 1500];
        uint256 paid = tip;
        for (uint256 i; i < n; ++i) {
            winners[i] = ranked[i];
            amounts[i] = (distributable * shares[i]) / 10_000;
            paid += amounts[i];
        }
        pot[league] -= paid;
        emit DaySettled(league, a.requestId, a.fromBlock, a.toBlock, winners, amounts, msg.sender, tip);
        _send(msg.sender, tip);
        for (uint256 i; i < n; ++i) _send(winners[i], amounts[i]);
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, address(this)
        ));
    }

    function _digest(Attestation calldata a) internal view returns (bytes32) {
        bytes32 structHash = keccak256(bytes.concat(
            abi.encode(ATTESTATION_TYPEHASH, a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock),
            abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
        ));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }

    // ───────── admin (cannot touch pots or vaults) ─────────

    function setPrices(uint256 single, uint256 pack) external onlyOwner {
        singlePrice = single;
        packPrice = pack;
    }

    /// @notice One-time set of each league's question hash, since they are only known once
    ///         the schedules (which name this contract) exist. Later changes use the timelock.
    function initQuestions(bytes32 arcadeQuestion, bytes32 agentQuestion) external onlyOwner {
        if (oracle.arcadeQuestion != bytes32(0) || oracle.agentQuestion != bytes32(0)) revert Timelocked();
        oracle.arcadeQuestion = arcadeQuestion;
        oracle.agentQuestion = agentQuestion;
        emit OracleChanged(oracle.signer, arcadeQuestion, agentQuestion);
    }

    /// @notice Oracle changes wait 2 days so players can see them coming.
    function queueOracle(address signer, bytes32 arcadeQuestion, bytes32 agentQuestion) external onlyOwner {
        pendingOracle = OracleConfig(signer, arcadeQuestion, agentQuestion);
        pendingOracleAt = block.timestamp + ORACLE_TIMELOCK;
        emit OracleChangeQueued(signer, arcadeQuestion, agentQuestion, pendingOracleAt);
    }

    function applyOracle() external {
        if (pendingOracleAt == 0 || block.timestamp < pendingOracleAt) revert Timelocked();
        oracle = pendingOracle;
        pendingOracleAt = 0;
        emit OracleChanged(oracle.signer, oracle.arcadeQuestion, oracle.agentQuestion);
    }

    function withdrawOps(address to, uint256 amount) external onlyOwner {
        opsBalance -= amount;
        _send(to, amount);
    }

    function transferOwnership(address to) external onlyOwner { owner = to; }

    // ───────── internals ─────────

    function _pull(address from, uint256 amount) internal {
        (bool ok, bytes memory data) = address(imd).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = address(imd).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
