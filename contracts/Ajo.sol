// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title Ajo - Decentralized ROSCA (Rotating Savings and Credit Association)
/// @notice Implements a rotating pool where members contribute and take turns receiving the pool
contract Ajo is AccessControl {
    // ---------------- ROLE DEFINITIONS ----------------
    /// @notice Role identifier for managers (can perform typical member operations)
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    /// @notice Role identifier for treasury operations
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    // ---------------- CUSTOM ERRORS ----------------
    error InvalidContribution();
    error AjoIsFull();
    error InitializationFailed();
    error ZeroAddress();
    error InvalidAmount();
    error UnauthorizedCaller();
    error CircleNotActive();
    error AlreadyWithdrawn();

    // ---------------- STATE VARIABLES ----------------
    /// @notice Maximum number of members allowed
    uint32 public maxMembers;
    
    /// @notice Contribution amount per cycle
    uint256 public contributionAmount;
    
    /// @notice Duration of each cycle in seconds
    uint256 public cycleDuration;
    
    /// @notice Current active round/cycle number
    uint256 public currentRound;
    
    /// @notice Total number of members
    uint32 public memberCount;
    
    /// @notice Flag indicating if circle is active
    bool public isActive;
    
    /// @notice Flag indicating if contract is initialized
    bool private _initialized;
    
    /// @notice Token address for contributions
    address public contributionToken;
    
    /// @notice Total pool balance
    uint256 public totalPool;
    
    /// @notice Mapping of member addresses to their data
    mapping(address => Member) public members;
    
    /// @notice Array of member addresses for iteration
    address[] public memberAddresses;
    
    /// @notice Mapping of round numbers to recipient
    mapping(uint256 => address) public roundRecipients;
    
    /// @notice Timestamp of last contribution deadline
    uint256 public nextDeadline;

    // ---------------- DATA STRUCTURES ----------------
    struct Member {
        uint256 totalContributed;
        uint256 totalReceived;
        uint32 missedContributions;
        bool isActive;
        bool hasReceivedPayout;
        uint256 joinedAt;
    }

    // ---------------- EVENTS ----------------
    event AjoCreated(
        address indexed admin, 
        uint256 contributionAmount, 
        uint32 maxMembers,
        uint256 cycleDuration
    );
    event MemberJoined(address indexed member, uint256 timestamp);
    event ContributionMade(address indexed member, uint256 amount, uint256 round);
    event PayoutDistributed(address indexed recipient, uint256 amount, uint256 round);
    event MemberRemoved(address indexed member, string reason);
    event CircleDissolved(address indexed admin, uint256 timestamp);
    event RoleGranted(bytes32 indexed role, address indexed account);

    // ---------------- MODIFIERS ----------------
    modifier onlyInitialized() {
        if (!_initialized) revert InitializationFailed();
        _;
    }

    modifier onlyActive() {
        if (!isActive) revert CircleNotActive();
        _;
    }

    modifier onlyMember(address _account) {
        if (!members[_account].isActive) revert UnauthorizedCaller();
        _;
    }

    // ---------------- CONSTRUCTOR ----------------
    /// @notice Contract constructor - deployer gets admin role
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // Note: _initialized remains false until initialize() is called
        // This allows the initialize() function to be called after deployment
        
        emit AjoCreated(
            msg.sender, 
            0, 
            0,
            0
        );
    }

    // ---------------- INITIALIZATION ----------------
    /// @notice Initialize the Ajo circle with parameters
    /// @param _admin Address that will receive admin privileges
    /// @param _manager Address that will receive manager privileges
    /// @param _contributionAmount Amount each member contributes per cycle
    /// @param _cycleDuration Duration of each cycle in seconds
    /// @param _maxMembers Maximum number of members allowed
    /// @param _token Address of the contribution token
    function initialize(
        address _admin,
        address _manager,
        uint256 _contributionAmount,
        uint256 _cycleDuration,
        uint32 _maxMembers,
        address _token
    ) external {
        // Prevent double initialization - use flag instead of checking state vars
        if (_initialized) revert InitializationFailed();
        if (_admin == address(0) || _token == address(0)) revert ZeroAddress();
        if (_contributionAmount == 0 || _maxMembers == 0 || _cycleDuration == 0) revert InvalidAmount();

        // Set configuration - using role-based access instead of direct admin variable
        contributionAmount = _contributionAmount;
        cycleDuration = _cycleDuration;
        maxMembers = _maxMembers;
        contributionToken = _token;
        currentRound = 1;
        nextDeadline = block.timestamp + _cycleDuration;
        _initialized = true;

        // Grant roles - admin gets admin role, manager gets manager role
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _manager);

        emit AjoCreated(_admin, _contributionAmount, _maxMembers);
    }

    // ---------------- ADMIN FUNCTIONS ----------------
    /// @notice Kick a member from the circle (admin only)
    /// @param _member Address of member to remove
    function kickMember(address _member) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _kickMember(_member, "kicked_by_admin");
    }

    /// @notice Emergency dissolve the circle (admin only)
    function dissolve() external onlyRole(DEFAULT_ADMIN_ROLE) {
        isActive = false;
        
        emit CircleDissolved(msg.sender, block.timestamp);
    }

    /// @notice Grant manager role to an address
    /// @param _account Address to grant manager role
    function grantManagerRole(address _account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MANAGER_ROLE, _account);
        emit RoleGranted(MANAGER_ROLE, _account);
    }

    /// @notice Revoke manager role from an address
    /// @param _account Address to revoke manager role
    function revokeManagerRole(address _account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MANAGER_ROLE, _account);
    }

    // ---------------- MANAGER FUNCTIONS ----------------
    /// @notice Add a new member to the circle (manager role)
    /// @param _newMember Address of new member
    function addMember(address _newMember) external onlyRole(MANAGER_ROLE) {
        if (_newMember == address(0)) revert ZeroAddress();
        if (memberCount >= maxMembers) revert AjoIsFull();
        if (members[_newMember].isActive) revert UnauthorizedCaller();

        members[_newMember] = Member({
            totalContributed: 0,
            totalReceived: 0,
            missedContributions: 0,
            isActive: true,
            hasReceivedPayout: false,
            joinedAt: block.timestamp
        });

        memberAddresses.push(_newMember);
        memberCount++;

        emit MemberJoined(_newMember, block.timestamp);
    }

    /// @notice Remove/kick a member (manager role)
    /// @param _member Address of member to remove
    /// @param _reason Reason for removal
    function removeMember(address _member, string calldata _reason) external onlyRole(MANAGER_ROLE) {
        _kickMember(_member, _reason);
    }

    /// @notice Boot a dormant member (manager role)
    /// @param _member Address of dormant member
    function bootDormantMember(address _member) external onlyRole(MANAGER_ROLE) {
        if (!members[_member].isActive) revert UnauthorizedCaller();
        
        // Mark as inactive
        members[_member].isActive = false;
        
        emit MemberRemoved(_member, "dormant_booted");
    }

    /// @notice Set KYC status for a member (manager role)
    /// @param _member Address of member
    /// @param _status KYC approval status
    function setKycStatus(address _member, bool _status) external onlyRole(MANAGER_ROLE) {
        // KYC status tracking can be added here
        // For now, this is a placeholder for compliance requirements
    }

    /// @notice Shuffle the payout rotation order (manager role)
    function shuffleRotation() external onlyRole(MANAGER_ROLE) {
        // Fisher-Yates shuffle for memberAddresses array
        uint256 length = memberAddresses.length;
        for (uint256 i = length - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encodePacked(block.timestamp, i))) % (i + 1);
            address temp = memberAddresses[i];
            memberAddresses[i] = memberAddresses[j];
            memberAddresses[j] = temp;
        }
    }

    // ---------------- MEMBER FUNCTIONS ----------------
    /// @notice Contribute to the pool
    function contribute() external onlyActive onlyMember(msg.sender) {
        _processContribution(msg.sender);
    }

    /// @notice Withdraw payout when it's your turn
    function withdrawPayout() external onlyActive onlyMember(msg.sender) {
        _processPayout(msg.sender);
    }

    // ---------------- INTERNAL FUNCTIONS ----------------
    function _kickMember(address _member, string memory _reason) internal {
        if (!members[_member].isActive) revert UnauthorizedCaller();
        
        members[_member].isActive = false;
        memberCount--;
        
        emit MemberRemoved(_member, _reason);
    }

    function _processContribution(address _member) internal {
        Member storage member = members[_member];
        
        // Check if contribution deadline passed
        if (block.timestamp > nextDeadline) {
            member.missedContributions++;
        }
        
        member.totalContributed += contributionAmount;
        totalPool += contributionAmount;
        
        // Update deadline for next round if all contributed
        uint32 activeMembers = _getActiveMemberCount();
        if (activeMembers == memberCount) {
            nextDeadline = block.timestamp + cycleDuration;
            currentRound++;
        }
        
        emit ContributionMade(_member, contributionAmount, currentRound);
    }

    function _processPayout(address _recipient) internal {
        Member storage member = members[_recipient];
        
        // Check if this member is the designated recipient for current round
        address roundRecipient = roundRecipients[currentRound];
        if (roundRecipient != _recipient && roundRecipient != address(0)) {
            revert UnauthorizedCaller();
        }
        
        if (member.hasReceivedPayout) revert AlreadyWithdrawn();
        
        member.hasReceivedPayout = true;
        member.totalReceived += contributionAmount * memberCount;
        totalPool -= contributionAmount * memberCount;
        
        emit PayoutDistributed(_recipient, contributionAmount * memberCount, currentRound);
    }

    function _getActiveMemberCount() internal view returns (uint32) {
        uint32 count = 0;
        for (uint256 i = 0; i < memberAddresses.length; i++) {
            if (members[memberAddresses[i]].isActive) {
                count++;
            }
        }
        return count;
    }

    // ---------------- VIEW FUNCTIONS ----------------
    /// @notice Get member information
    /// @param _member Address of member
    /// @return Member struct data
    function getMember(address _member) external view returns (Member memory) {
        return members[_member];
    }

    /// @notice Get all member addresses
    /// @return Array of member addresses
    function getAllMembers() external view returns (address[] memory) {
        return memberAddresses;
    }

    /// @notice Check if address has manager role
    /// @param _account Address to check
    /// @return bool indicating if account has manager role
    function isManager(address _account) external view returns (bool) {
        return hasRole(MANAGER_ROLE, _account);
    }

    /// @notice Check circle status
    /// @return isActive, currentRound, memberCount, totalPool
    function getCircleStatus() external view returns (
        bool _isActive,
        uint256 _currentRound,
        uint32 _memberCount,
        uint256 _totalPool
    ) {
        return (isActive, currentRound, memberCount, totalPool);
    }
}
