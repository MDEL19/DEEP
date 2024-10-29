import { ethers } from "hardhat";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { entryPoint07Address } from "viem/account-abstraction";

const name = "SimpleAccountFactory";

const deploySimpleAccountFactory: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, network } = hre;
  const { deploy } = deployments;

  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();

  console.log(`Deploying ${name} from ${deployerAddress} on ${network.name}`);

  const simpleAccountFactory = await deploy("SimpleAccountFactory", {
    from: deployerAddress,
    args: [entryPoint07Address],
    log: true,
    deterministicDeployment: true,
    gasLimit: 6e6,
  });

  console.log("SimpleAccountFactory deployed to:", simpleAccountFactory.address);

  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("Verifying contract on Etherscan");
    try {
      await hre.run("verify:verify", {
        address: simpleAccountFactory.address,
        constructorArguments: [entryPoint07Address],
      });
      console.log("SimpleAccountFactory verified on Etherscan");
    } catch (error) {
      console.error("Error verifying contract:", error);
    }
  }
};

deploySimpleAccountFactory.tags = [name];

export default deploySimpleAccountFactory;
