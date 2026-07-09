//
//  StorageSidecarTests.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-07.
//

import XCTest

@testable import NyaruDB2

/// Integrity tests for the clean-state sidecar and free-slot reuse: a
/// corrupt or forged sidecar must never cause a live record to be
/// overwritten.
final class StorageSidecarTests: XCTestCase {
  private var dir: URL!
  private var fileURL: URL!
  private var stateURL: URL!

  override func setUp() async throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("nyaru-sidecar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    fileURL = dir.appendingPathComponent("shard.nyaru")
    stateURL = URL(fileURLWithPath: fileURL.path + ".state")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func payload(_ i: Int, size: Int = 40) -> Data {
    Data(repeating: UInt8(i % 251), count: size)
  }

  /// Builds a shard with live records and free slots, closed cleanly so the
  /// sidecar exists. Returns the offsets of the live records.
  private func makeShardWithFreeSlots() throws -> [UInt64] {
    let file = try SlottedFile(url: fileURL)
    var offsets: [UInt64] = []
    for i in 0..<6 {
      offsets.append(try file.append(payload: payload(i), compression: .none))
    }
    // Tombstone records 1 and 3 → two free slots.
    try file.tombstone(at: offsets[1])
    try file.tombstone(at: offsets[3])
    try file.close()
    return [offsets[0], offsets[2], offsets[4], offsets[5]]
  }

  private func readAllLivePayloads(_ file: SlottedFile) throws -> [UInt64: Data] {
    var out: [UInt64: Data] = [:]
    try file.forEachLive { record in out[record.offset] = record.payload }
    return out
  }

  func testBitFlippedSidecarIsRejectedAndOpenScans() throws {
    let liveOffsets = try makeShardWithFreeSlots()

    // Flip one bit inside the slot list (past the 22-byte fixed prefix).
    var sidecar = try Data(contentsOf: stateURL)
    XCTAssertGreaterThan(sidecar.count, 26, "expected sidecar with slots")
    sidecar[24] ^= 0x40
    try sidecar.write(to: stateURL)

    let reopened = try SlottedFile(url: fileURL)
    // The CRC rejects the sidecar and the open falls back to a scan, so the
    // state matches reality: 4 live, 2 tombstoned.
    XCTAssertEqual(reopened.liveCount, 4)
    XCTAssertEqual(reopened.tombstoneCount, 2)
    let live = try readAllLivePayloads(reopened)
    XCTAssertEqual(Set(live.keys), Set(liveOffsets))
    try reopened.close()
  }

  func testForgedFreeSlotOverLiveRecordIsNotOverwritten() throws {
    let liveOffsets = try makeShardWithFreeSlots()
    let victimOffset = liveOffsets[0]
    let victimPayload = payload(0)

    // Forge a structurally valid v2 sidecar (correct CRC) whose only free
    // slot points at a LIVE record. This models corruption that happens to
    // keep the CRC consistent, or any future free-list bookkeeping bug —
    // the last line of defence is the header check at reuse time.
    let victimCapacity = SlottedFile.roundUpCapacity(UInt32(victimPayload.count))
    let fileSize = try Data(contentsOf: fileURL).count
    var forged = Data()
    forged.append(contentsOf: [0x4E, 0x59, 0x53, 0x31])  // "NYS1"
    Binary.append(UInt16(2), to: &forged)
    Binary.append(UInt64(fileSize), to: &forged)
    Binary.append(UInt32(4), to: &forged)  // liveCount
    Binary.append(UInt32(1), to: &forged)  // slotCount
    Binary.append(victimOffset, to: &forged)
    Binary.append(victimCapacity, to: &forged)
    Binary.append(Compressor.crc32Checksum(forged), to: &forged)
    try forged.write(to: stateURL)

    let reopened = try SlottedFile(url: fileURL)
    // Small enough to best-fit the forged slot.
    let newOffset = try reopened.append(payload: payload(9, size: 8), compression: .none)

    XCTAssertNotEqual(newOffset, victimOffset, "live slot must not be reused")
    let victim = try reopened.read(at: victimOffset)
    XCTAssertEqual(victim?.payload, victimPayload, "live record was overwritten")
    let live = try readAllLivePayloads(reopened)
    XCTAssertEqual(live[victimOffset], victimPayload)
    XCTAssertEqual(live[newOffset], payload(9, size: 8))
    try reopened.close()
  }

  func testLegacyV1SidecarFallsBackToScan() throws {
    _ = try makeShardWithFreeSlots()

    // Rewrite the sidecar in the v1 layout (no CRC).
    var v1 = try Data(contentsOf: stateURL)
    v1 = v1.prefix(v1.count - 4)  // strip CRC
    v1[4] = 1  // version low byte (little-endian u16)
    try v1.write(to: stateURL)

    let reopened = try SlottedFile(url: fileURL)
    XCTAssertEqual(reopened.liveCount, 4)
    XCTAssertEqual(reopened.tombstoneCount, 2)
    try reopened.close()
  }

  func testValidSidecarStillAdoptedAndSlotsReusable() throws {
    _ = try makeShardWithFreeSlots()

    let reopened = try SlottedFile(url: fileURL)
    XCTAssertEqual(reopened.liveCount, 4)
    XCTAssertEqual(reopened.tombstoneCount, 2)
    // A genuinely tombstoned slot passes the reuse validation.
    let sizeBefore = reopened.sizeInBytes()
    _ = try reopened.append(payload: payload(7, size: 8), compression: .none)
    XCTAssertEqual(reopened.sizeInBytes(), sizeBefore, "append should reuse a free slot")
    try reopened.close()
  }
}
