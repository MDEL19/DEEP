import { ethers } from "hardhat";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { entryPoint07Address } from "viem/account-abstraction";

const name = "VerifyingPaymaster";

const deployVerifyingPaymaster: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, network } = hre;
  const { deploy } = deployments;

  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();

  console.log(`Deploying ${name} from ${deployerAddress} on ${network.name}`);

  const initialVerifier = deployerAddress;

  const verifyingPaymaster = await deploy("VerifyingPaymaster", {
    from: deployerAddress,
    args: [entryPoint07Address, initialVerifier],
    log: true,
    deterministicDeployment: process.env.SALT ?? true,
    gasLimit: 6e6,
  });

  console.log("VerifyingPaymaster deployed to:", verifyingPaymaster.address);

  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("Verifying contract on Etherscan");
    try {
      await hre.run("verify:verify", {
        address: verifyingPaymaster.address,
        constructorArguments: [entryPoint07Address, initialVerifier],
      });
      console.log("VerifyingPaymaster verified on Etherscan");
    } catch (error) {
      console.error("Error verifying contract:", error);
    }
  }
};

deployVerifyingPaymaster.tags = [name];

export default deployVerifyingPaymaster;
