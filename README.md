# open-g2-hub

A standalone, completely offline replacement system for the Even Realities G2 smart glasses companion app. It runs on unmodified stock firmware and provides full control over the native dashboard widgets and the AI microphone stream.

## Protocol Breakdown

### 1. Transport & Characteristics
The glasses consist of two independent BLE peripherals (Left and Right lens). Both must be bonded at the OS level. The system communicates via base UUID `00002760-08c2-11e1-9073-0e8ac72e____` using three primary suffixes:

*   **`5401` (Write):** Control frames for commands, widget updates, and configuration.
*   **`5402` (Notify):** Device events and command replies.
*   **`6402` (Notify):** Raw microphone audio data. Subscribing to this channel on the Left lens captures the un-headered LC3 audio streams during voice tasks.

### 2. Wire Frame Format
Control messages sent over characteristic `5401` must follow this exact byte alignment:

```text
AA  21  seq  len  total  num  SID  flag  payload...  crc_lo crc_hi
```

*   **`AA`**: Packet head identifier.
*   **`21`**: Routing byte (Phone to Glasses). Replies from the glasses use `12`.
*   **`seq`**: Sync ID byte, randomized per transmission block.
*   **`len`**: Payload segment length (includes the 2 trailing CRC bytes if it is the final packet).
*   **`total`**: Total number of packets in the message (1-based).
*   **`num`**: Current packet sequence number (1 to total).
*   **`SID`**: Service ID determining the destination feature block.
*   **`flag`**: Control flag byte. Set to `0x20` (`FLAG_REQUEST`) for control commands.
*   **`crc_lo / crc_hi`**: Little-endian CRC-16/CCITT-FALSE checksum (polynomial `0x1021`, initial value `0xFFFF`) calculated strictly over the payload.

### 3. Core Service IDs (SIDs) & Logic

*   **Session Initialization (SID `0x80`):** Pushes device configuration arrays (`08 04 10 <magic> 1a 04 08 01 10 04`) to both lenses to establish trusted data routing.
*   **Prelude (SID `0x01`):** Sends cmd 2 (`Dashboard_Receive`) with an empty body using a fixed magic number (156) to the Right lens to initialize layout mapping.
*   **EvenHub Heartbeat (SID `0xE0`):** Requires cmd 12 to be sent to the Right lens every ~4 seconds as a fire-and-forget message. Halting this loop causes the glasses to trigger a connection-lost error.
*   **Widget Text Injection:** Pushing manually packed Google Protobuf data through SID `0x01` routes text changes directly into the native layout structures of the built-in widgets (News feed, Tasks, and Calendar).

## Media & Interface Showcase

Below are images and animations showing the standalone hub running interface synchronization, custom widget data updates, and native AI microphone captures.

![Interface Setup](assets/dashboard-demo.jpg)

---

## License
MIT License - see LICENSE file for details.
