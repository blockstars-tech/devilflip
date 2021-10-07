import "@nomiclabs/hardhat-truffle5";
import "@typechain/hardhat";
import { HardhatUserConfig } from "hardhat/types";

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: "0.6.6",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  typechain: {
    target: "truffle-v5",
  },
  networks: {
    test: {
      url: "http://127.0.0.1:8545",
    },
    hardhat: {
      chainId: 1,
      forking: {
        url: "http://192.168.2.107:9991"
      },
      accounts: {
        mnemonic: "test test test test test test test test test test test test",
        count: 10,
        accountsBalance: "1000000000000000000000000",
      }
    },
    node_network: {
      url: "http://127.0.0.1:8545",
    },
    rinkeby: {
      chainId: 4,
      url: "https://rinkeby.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161",
    }
  },
};

export default config;
