

##  Dirac Honeypot Strategy Contract

This repository contains the implementation of the **Dirac Honeypot Perps Strategy** —
a smart contract designed to interact seamlessly with the **Honeypot Perps Protocol**, built on top of **Orderly** infrastructure.

---

###  Project Overview

####  **Events**

**File:** `Events.sol`
Defines all **events** emitted by the Dirac Strategy, allowing external systems 
to track state changes and contract activity.

---

####  **Data**

**File:** `Data.sol`
Contains the **core data structures** (structs, enums, constants) shared across contracts — 
providing a unified schema for strategy state and protocol interactions.

---

####  **Interfaces**

**Folder:** `interfaces/`
Holds the **interface definitions** for interacting with external contracts, ensuring modularity and 
clean integration with the Honeypot and Orderly protocols.

---

####  **Contracts**

**Folder:** `src/contracts/`

* **Controller.sol**
  Governs the **execution logic** of the strategy.

    * Checks market conditions before opening or closing positions
    * Handles **emergency stop** and **risk control** scenarios

* **DiracUp.sol**
  The **main strategy contract**, orchestrating all interactions between the Dirac base contracts and the Honeypot Perps Protocol.
  Combines control, event emission, and data management into a unified on-chain strategy.

---

###  Summary

| Component         | File/Path                         | Purpose                               |
| ----------------- | --------------------------------- | ------------------------------------- |
| **Events**        | `Events.sol`                      | Emits key protocol events             |
| **Data**          | `Data.sol`                        | Defines structs, enums, and constants |
| **Interfaces**    | `interfaces/`                     | Contract integration interfaces       |
| **Controller**    | `src/contracts/Controller.sol`    | Risk & strategy control logic         |
| **DiracHoneypotV1** | `src/contracts/DiracHoneypotV1.sol` | Core strategy logic                   |

---
