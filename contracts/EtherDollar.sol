pragma solidity ^0.5.0;

import "@openzeppelin/contracts/token/ERC20/ERC20Mintable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";



/**
 * @title EtherDollar token contract.
  * @dev ERC20 token contract.
 */
contract EtherDollar is ERC20Mintable, ERC20Burnable, Ownable {
    string public constant name = "EtherDollar";
    string public constant symbol = "ETD";
    uint32 public constant decimals = 2;

}
