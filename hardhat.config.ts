import "@nomicfoundation/hardhat-verify";
import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import * as dotenv from "dotenv";
import "hardhat-deploy";
import type { HardhatUserConfig } from "hardhat/config";
import type { NetworkUserConfig } from "hardhat/types";
import "solidity-coverage";

dotenv.config();

const SALT = "0x90d8084deab30c2a37c45e8d47f49f2f7965183cb6990a98943ef94940681de3";
process.env.SALT = process.env.SALT ?? SALT;

const mnemonic = process.env.MNEMONIC ?? "";
const alchemyApiKey = process.env.ALCHEMY_API_KEY ?? "";

const chainIds = {
  ganache: 1337,
  hardhat: 31337,
  mainnet: 1,
  sepolia: 11155111,
  "base-mainnet": 8453,
  "base-sepolia": 84532,
  "night-testnet": 86868,
};

function getChainConfig(chain: keyof typeof chainIds): NetworkUserConfig {
  let jsonRpcUrl: string;
  switch (chain) {
    case "mainnet":
    case "sepolia":
      jsonRpcUrl = "https://eth-" + chain + ".g.alchemy.com/v2/" + alchemyApiKey;
      break;
    case "base-mainnet":
    case "base-sepolia":
      jsonRpcUrl = "https://" + chain + ".g.alchemy.com/v2/" + alchemyApiKey;
      break;
    case "night-testnet":
      jsonRpcUrl = "https://rpc-night-testnet-brk51d2fuk.t.conduit.xyz";
      break;
    default:
      jsonRpcUrl = "";
  }
  return {
    accounts: {
      count: 10,
      mnemonic,
      path: "m/44'/60'/0'/0",
    },
    chainId: chainIds[chain],
    url: jsonRpcUrl,
  };
}

const optimizedComilerSettings = {
  version: "0.8.23",
  settings: {
    optimizer: { enabled: true, runs: 1000000 },
    viaIR: true,
  },
};

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  solidity: {
    compilers: [
      {
        version: "0.8.23",
        settings: {
          optimizer: { enabled: true, runs: 800 },
          metadata: {
            bytecodeHash: "none",
          },
        },
      },
    ],
    overrides: {
      "contracts/core/EntryPoint.sol": optimizedComilerSettings,
      "contracts/samples/SimpleAccount.sol": optimizedComilerSettings,
    },
  },
  networks: {
    hardhat: {
      accounts: {
        mnemonic,
      },
      chainId: chainIds.hardhat,
    },
    ganache: {
      accounts: {
        mnemonic,
      },
      chainId: chainIds.ganache,
      url: "http://localhost:8545",
    },
    mainnet: getChainConfig("mainnet"),
    sepolia: getChainConfig("sepolia"),
    "base-mainnet": getChainConfig("base-mainnet"),
    "base-sepolia": getChainConfig("base-sepolia"),
    "night-testnet": getChainConfig("night-testnet"),
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY ?? "",
      sepolia: process.env.ETHERSCAN_API_KEY ?? "",
      "base-mainnet": process.env.BASESCAN_API_KEY ?? "",
      "base-sepolia": process.env.BASESCAN_API_KEY ?? "",
      "night-testnet": "...",
    },
    customChains: [
      {
        network: "base-mainnet",
        chainId: chainIds["base-mainnet"],
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
      {
        network: "base-sepolia",
        chainId: chainIds["base-sepolia"],
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
      {
        network: "night-testnet",
        chainId: chainIds["night-testnet"],
        urls: {
          apiURL: "https://explorer-night-testnet-brk51d2fuk.t.conduit.xyz/api",
          browserURL: "https://explorer-night-testnet-brk51d2fuk.t.conduit.xyz",
        },
      },
    ],
  },
  mocha: {
    timeout: 10000,
  },
};

// coverage chokes on the "compilers" settings
if (process.env.COVERAGE != null) {
  // @ts-ignore
  config.solidity = config.solidity.compilers[0];
}

export default config;
