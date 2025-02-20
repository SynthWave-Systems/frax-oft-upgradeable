// SPDX-License-Identifier: ISC
pragma solidity ^0.8.19;

import { Script } from "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "frax-template/src/Constants.sol";
import { console } from "frax-std/FraxTest.sol";

import { SerializedTx, SafeTxUtil } from "scripts/SafeBatchSerialize.sol";
import { FraxOFTUpgradeable } from "contracts/FraxOFTUpgradeable.sol";
import { FraxProxyAdmin } from "contracts/FraxProxyAdmin.sol";
import { ImplementationMock } from "contracts/mocks/ImplementationMock.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MessagingParams, MessagingReceipt, Origin } from "@fraxfinance/layerzero-v2-upgradeable/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { EndpointV2 } from "@fraxfinance/layerzero-v2-upgradeable/protocol/contracts/EndpointV2.sol";
import { SetConfigParam, IMessageLibManager} from "@fraxfinance/layerzero-v2-upgradeable/protocol/contracts/interfaces/IMessageLibManager.sol";

import { OptionsBuilder } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/libs/OptionsBuilder.sol";
import { EnforcedOptionParam, IOAppOptionsType3 } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { IOAppCore } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oapp/interfaces/IOAppCore.sol";
import { SendParam, OFTReceipt, MessagingFee, IOFT } from "@fraxfinance/layerzero-v2-upgradeable/oapp/contracts/oft/interfaces/IOFT.sol";

import { ProxyAdmin, TransparentUpgradeableProxy } from "@fraxfinance/layerzero-v2-upgradeable/messagelib/contracts/upgradeable/proxy/ProxyAdmin.sol";
import { UlnConfig } from "@fraxfinance/layerzero-v2-upgradeable/messagelib/contracts/uln/UlnBase.sol";
import { Constant } from "@fraxfinance/layerzero-v2-upgradeable/messagelib/test/util/Constant.sol";
    
contract BaseL0Script is Script {

    using OptionsBuilder for bytes;
    using stdJson for string;
    using Strings for uint256;

    uint256 public oftDeployerPK = vm.envUint("PK_OFT_DEPLOYER");
    uint256 public configDeployerPK = vm.envUint("PK_CONFIG_DEPLOYER");
    uint256 public senderDeployerPK = vm.envUint("PK_SENDER_DEPLOYER");

    /// @dev: required to be alphabetical to conform to https://book.getfoundry.sh/cheatcodes/parse-json
    struct L0Config {
        string RPC;
        uint256 chainid;
        address delegate;
        address dvnHorizen;
        address dvnL0;
        uint256 eid;
        address endpoint;
        address receiveLib302;
        address sendLib302;
    }
    L0Config[] public legacyConfigs;
    L0Config[] public proxyConfigs;
    L0Config[] public evmConfigs;
    L0Config[] public nonEvmConfigs;
    L0Config[] public allConfigs; // legacy, proxy, and non-evm allConfigs
    L0Config public broadcastConfig; // config of actively-connected (broadcasting) chain
    L0Config public simulateConfig;  // Config of the simulated chain
    L0Config[] public broadcastConfigArray; // length of 1 of broadcastConfig
    bool public activeLegacy; // true if we're broadcasting to legacy chain (setup by L0 team)

    /// @dev alphabetical order as json is read in by keys alphabetically.
    struct NonEvmPeer {
        bytes32 fpi;
        bytes32 frax;
        bytes32 frxEth;
        bytes32 fxs;
        bytes32 sFrax;
        bytes32 sFrxEth;
    }
    bytes32[][] public nonEvmPeersArrays;

    // Mock implementation used to enable pre-determinsitic proxy creation
    address public implementationMock;

    // Deployed proxies
    address public proxyAdmin;
    address public fxsOft;
    address public sfrxUsdOft;
    address public sfrxEthOft;
    address public frxUsdOft;
    address public frxEthOft;
    address public fpiOft;
    uint256 public numOfts;

    // 1:1 match between these arrays for setting peers
    address[] public legacyOfts;
    address[] public expectedProxyOfts; // to assert against proxyOfts
    address[] public proxyOfts; // the OFTs deployed through `DeployFraxOFTProtocol.s.sol`

    EnforcedOptionParam[] public enforcedOptionParams;

    SetConfigParam[] public setConfigParams;

    SerializedTx[] public serializedTxs;

    string public json;

    function version() public virtual pure returns (uint256, uint256, uint256) {
        return (1, 2, 4);
    }

    modifier broadcastAs(uint256 privateKey) {
        vm.startBroadcast(privateKey);
        _;
        vm.stopBroadcast();
    }

    modifier simulateAndWriteTxs(
        L0Config memory _simulateConfig
    ) virtual {
        // Clear out any previous txs
        delete enforcedOptionParams;
        delete setConfigParams;
        delete serializedTxs;

        // store for later referencing
        simulateConfig = _simulateConfig;

        // if we're simulating fraxtal, overwrite the proxy (s)frxUSD OFTs to the standalone lockboxes.  Otherwise, use the re-usable addrs
        _overwriteFrxUsdAddrs();

        // Simulate fork as delegate (aka msig) as we're crafting txs within the modified function
        vm.createSelectFork(_simulateConfig.RPC);
        vm.startPrank(_simulateConfig.delegate);
        _;
        vm.stopPrank();

        // serialized txs were pushed within the modified function- write to storage
        new SafeTxUtil().writeTxs(serializedTxs, filename());
    }

    // Configure (s)frxUSD addresses to the standalone fraxtal lockboxes, otherwise re-usable OFTs
    function _overwriteFrxUsdAddrs() public virtual {
        // skip overwrite if there are no proxyOfts to write to
        if (proxyOfts.length != 6) return;

        /// @dev see setUp() to reference array positioning
        if (simulateConfig.chainid == 252) {
            // https://github.com/FraxFinance/frax-oft-upgradeable?tab=readme-ov-file#fraxtal-standalone-frxusdsfrxusd-lockboxes
            proxyOfts[1] = 0x88Aa7854D3b2dAA5e37E7Ce73A1F39669623a361; // sfrxUSD
            proxyOfts[3] = 0x96A394058E2b84A89bac9667B19661Ed003cF5D4; // frxUSD
        } else {
            // https://github.com/FraxFinance/frax-oft-upgradeable?tab=readme-ov-file#proxy-upgradeable-ofts
            proxyOfts[1] = 0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0;
            proxyOfts[3] = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
        }
    }

    function filename() public view virtual returns (string memory) {
        string memory root = vm.projectRoot();
        root = string.concat(root, '/scripts/DeployFraxOFTProtocol/txs/');

        string memory name = string.concat(broadcastConfig.chainid.toString(), "-");
        name = string.concat(name, simulateConfig.chainid.toString());
        name = string.concat(name, ".json");
        return string.concat(root, name);
    }

    function setUp() public virtual {
        // Set constants based on deployment chain id
        loadJsonConfig();

        /// @dev: this array maintains the same token order as proxyOfts and the addrs are confirmed on eth mainnet, blast, base, and metis.
        legacyOfts.push(0x23432452B720C80553458496D4D9d7C5003280d0); // fxs
        legacyOfts.push(0xe4796cCB6bB5DE2290C417Ac337F2b66CA2E770E); // sfrxUSD
        legacyOfts.push(0x1f55a02A049033E3419a8E2975cF3F572F4e6E9A); // sfrxETH
        legacyOfts.push(0x909DBdE1eBE906Af95660033e478D59EFe831fED); // frxUSD
        legacyOfts.push(0xF010a7c8877043681D59AD125EbF575633505942); // frxETH
        legacyOfts.push(0x6Eca253b102D41B6B69AC815B9CC6bD47eF1979d); // FPI
        numOfts = legacyOfts.length;

        // aray of semi-pre-determined upgradeable OFTs
        expectedProxyOfts.push(0x64445f0aecC51E94aD52d8AC56b7190e764E561a); // fxs
        expectedProxyOfts.push(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0); // sfrxUSD
        expectedProxyOfts.push(0x3Ec3849C33291a9eF4c5dB86De593EB4A37fDe45); // sfrxETH
        expectedProxyOfts.push(0x80Eede496655FB9047dd39d9f418d5483ED600df); // frxUSD
        expectedProxyOfts.push(0x43eDD7f3831b08FE70B7555ddD373C8bF65a9050); // frxETH
        expectedProxyOfts.push(0x90581eCa9469D8D7F5D3B60f4715027aDFCf7927); // FPI
    }

    function loadJsonConfig() public virtual {
        string memory root = vm.projectRoot();
        
        // L0Config.json

        string memory path = string.concat(root, "/scripts/L0Config.json");
        json = vm.readFile(path);

        // legacy
        L0Config[] memory legacyConfigs_ = abi.decode(json.parseRaw(".Legacy"), (L0Config[]));
        for (uint256 i=0; i<legacyConfigs_.length; i++) {
            L0Config memory config_ = legacyConfigs_[i];
            if (config_.chainid == block.chainid) {
                broadcastConfig = config_;
                broadcastConfigArray.push(config_);
                activeLegacy = true;
            }
            legacyConfigs.push(config_);
            allConfigs.push(config_);
            evmConfigs.push(config_);
        }

        // proxy (active deployment loaded as broadcastConfig)
        L0Config[] memory proxyConfigs_ = abi.decode(json.parseRaw(".Proxy"), (L0Config[]));
        for (uint256 i=0; i<proxyConfigs_.length; i++) {
            L0Config memory config_ = proxyConfigs_[i];
            if (config_.chainid == block.chainid) {
                broadcastConfig = config_;
                broadcastConfigArray.push(config_);
                activeLegacy = false;
            }
            proxyConfigs.push(config_);
            allConfigs.push(config_);
            evmConfigs.push(config_);
        }

        // Non-EVM allConfigs
        /// @dev as foundry cannot deploy to non-evm, a non-evm chain will never be the active/connected chain
        L0Config[] memory nonEvmConfigs_ = abi.decode(json.parseRaw(".Non-EVM"), (L0Config[]));
        for (uint256 i=0; i<nonEvmConfigs_.length; i++) {
            L0Config memory config_ = nonEvmConfigs_[i];
            nonEvmConfigs.push(config_);
            allConfigs.push(config_);
        }

        // NonEvmPeers.json

        path = string.concat(root, "/scripts/NonEvmPeers.json");
        json = vm.readFile(path);

        NonEvmPeer[] memory nonEvmPeers = abi.decode(json.parseRaw(".Peers"), (NonEvmPeer[]));
        
        // As json has to be ordered alphabetically, sort the peer addresses in the order of OFT deployment
        for (uint256 i=0; i<nonEvmPeers.length; i++) {
            NonEvmPeer memory peer = nonEvmPeers[i];
            bytes32[] memory peerArray = new bytes32[](6);
            peerArray[0] = peer.fxs;
            peerArray[1] = peer.sFrax;
            peerArray[2] = peer.sFrxEth;
            peerArray[3] = peer.frax;
            peerArray[4] = peer.frxEth;
            peerArray[5] = peer.fpi;

            nonEvmPeersArrays.push(peerArray);
        }
    }

    function isStringEqual(string memory _a, string memory _b) public pure returns (bool) {
        return keccak256(abi.encodePacked(_a)) == keccak256(abi.encodePacked(_b));
    }

    function addressToBytes32(address _addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

}