import Foundation
import SwiftData
import Testing
@testable import OneShot

@MainActor
struct StoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_300_000)
    /// The context doesn't keep its container alive, so the test holds it.
    private let container = try! Store.inMemory()
    private var context: ModelContext { container.mainContext }
    private let lays = Product(id: "lays", nameEN: "Lay's", nameTH: "เลย์", price: 20, barcode: nil)
    private let pocky = Product(id: "pocky", nameEN: "Pocky", nameTH: "ป๊อกกี้", price: Decimal(string: "19.9")!, barcode: nil)

    @Test func salesRoundTripInOrderAndRefundOnlyOnce() throws {
        let paid = try SalesLog.record([BillLine(product: lays, quantity: 2), BillLine(product: pocky, quantity: 1)],
                                       total: Decimal(string: "59.9")!, method: .cash, received: 100, at: t0, in: context)
        let refund = try SalesLog.refund(paid, at: t0.addingTimeInterval(60), in: context)
        #expect(throws: SalesLog.AlreadyRefunded.self) { try SalesLog.refund(paid, in: context) }
        #expect(throws: SalesLog.AlreadyRefunded.self) { try SalesLog.refund(refund, in: context) }

        let all = SalesLog.all(in: context)
        #expect(all == [paid, refund])   // lines keep the bill's order; Decimal survives exactly
        #expect(all[0].change == Decimal(string: "40.1")!)
    }

    @Test func stockAndClosesPersist() throws {
        var stock = StockBook(levels: [:])
        stock.set("lays", count: 10, reorderAt: 4)
        try stock.save(to: context)
        stock.receive("lays", 6)
        try stock.save(to: context)   // updates the row, never a second "lays"
        #expect(StockBook.load(from: context)["lays"] == StockLevel(count: 16, reorderAt: 4))
        #expect(try context.fetchCount(FetchDescriptor<StockRecord>()) == 1)

        let close = DayClose(date: t0, float: 500, cashSales: 1240, counted: 1720, sales: 23, revenue: 1890)
        try DayCloseLog.save(close, in: context)
        #expect(DayCloseLog.all(in: context) == [close])
    }

    @Test func oldJSONBooksAreImportedOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = #"[{"date":0,"lines":[{"sku":"a","name":"A","quantity":1,"amount":20}],"total":20}]"#
        try Data(old.utf8).write(to: folder.appending(path: "sales.json"))
        try Data(#"{"a":{"count":3,"reorderAt":5}}"#.utf8).write(to: folder.appending(path: "stock.json"))
        try Data("not json".utf8).write(to: folder.appending(path: "closings.json"))

        Store.importLegacyJSON(into: context, folder: folder)
        Store.importLegacyJSON(into: context, folder: folder)   // second launch: nothing new

        let sales = SalesLog.all(in: context)
        #expect(sales.count == 1 && sales[0].total == 20 && sales[0].id != nil)
        #expect(StockBook.load(from: context)["a"]?.count == 3)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "sales.json.imported").path()))
        // Unreadable file: left in place, nothing half-imported.
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "closings.json").path()))
        #expect(DayCloseLog.all(in: context).isEmpty)
    }

    @Test func storeThatWontOpenIsSetAsideNotFatal() throws {
        // A space, like the real "Application Support": a percent-encoded path finds no file to move.
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString) Application Support")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let healthy = ModelConfiguration(url: folder.appending(path: "books.store"))
        do {
            let (first, aside) = Store.open(healthy)
            try SalesLog.record([BillLine(product: lays, quantity: 1)], total: 20, method: .cash, at: t0, in: first.mainContext)
            #expect(aside == nil)
        }
        let (reopened, aside) = Store.open(healthy)   // V1 and its migration plan read back their own store
        #expect(aside == nil && SalesLog.all(in: reopened.mainContext).count == 1)

        let junk = Data("not a database".utf8)
        try junk.write(to: folder.appending(path: "broken.store"))
        let (fresh, setAside) = Store.open(ModelConfiguration(url: folder.appending(path: "broken.store")))
        let kept = try #require(setAside)
        #expect(try Data(contentsOf: kept.appending(path: "broken.store")) == junk)   // kept as it was, for recovery
        #expect(SalesLog.all(in: fresh.mainContext).isEmpty)
        try SalesLog.record([BillLine(product: lays, quantity: 1)], total: 20, method: .cash, at: t0, in: fresh.mainContext)
        #expect(SalesLog.all(in: fresh.mainContext).count == 1)   // the new books take sales
    }

    @Test func v1StoreMigratesToV2KeepingItsBooks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "books.store")
        let old = Sale(id: UUID(), date: t0, lines: [SaleLine(sku: "lays", name: "Lay's", quantity: 2, amount: 40)],
                       total: 40, method: .cash, received: 100)
        do {   // a store as the 18 Oct builds wrote it
            let v1 = try ModelContainer(for: Schema(versionedSchema: StoreV1.self), configurations: ModelConfiguration(url: url))
            v1.mainContext.insert(StoreV1.SaleRecord(old))
            try v1.mainContext.save()
        }

        let (current, aside) = Store.open(ModelConfiguration(url: url))
        #expect(aside == nil)   // migrated, not set aside
        #expect(SalesLog.all(in: current.mainContext) == [old])
        let timed = try SalesLog.record([BillLine(product: lays, quantity: 1)], total: 20, method: .cash,
                                        ringUp: 3.5, autoUnits: 1, at: t0.addingTimeInterval(60), in: current.mainContext)
        #expect(SalesLog.all(in: current.mainContext) == [old, timed])   // ringUp and autoUnits are kept now
    }

    @Test func backupPutBackDoesNotDoubleTheBooks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paid = try SalesLog.record([BillLine(product: lays, quantity: 2), BillLine(product: pocky, quantity: 1)],
                                       total: Decimal(string: "59.9")!, method: .cash, received: 100, at: t0, in: context)
        try SalesLog.refund(paid, at: t0.addingTimeInterval(60), in: context)
        try SalesLog.record([BillLine(product: lays, quantity: 1)], total: Decimal(string: "12345678.99")!,
                            method: .promptPay, ringUp: 2.5, autoUnits: 1, at: t0.addingTimeInterval(120), in: context)
        var stock = StockBook(levels: [:])
        stock.set("lays", count: 9, reorderAt: 3)
        try stock.save(to: context)
        try DayCloseLog.save(DayClose(date: t0, float: 500, cashSales: 0, counted: 500, sales: 2, revenue: 20), in: context)
        let sales = SalesLog.all(in: context), closes = DayCloseLog.all(in: context)

        let files = try Store.backUp(container, to: folder)
        #expect(files.map(\.lastPathComponent) == ["sales.json", "closings.json", "stock.json"])
        stock.receive("lays", 5)   // a delivery after the backup
        try stock.save(to: context)
        Store.importLegacyJSON(into: context, folder: folder)   // put back while the same books are still here
        #expect(SalesLog.all(in: context) == sales && DayCloseLog.all(in: context) == closes)
        #expect(StockBook.load(from: context)["lays"]?.count == 14)   // the live count, not the backup's 9
        #expect(try context.fetchCount(FetchDescriptor<LineRecord>()) == 5)   // 2 + 2 refunded + 1, none doubled

        // A file is input: it can't refund a sale a second time, or bring one sale in twice.
        let again = SalesLog.reversal(of: paid, id: paid.id!, at: t0.addingTimeInterval(180))
        try JSONEncoder().encode([again, again]).write(to: folder.appending(path: "sales.json"))
        Store.importLegacyJSON(into: context, folder: folder)
        #expect(SalesLog.all(in: context) == sales)

        let restored = try Store.inMemory()   // the real restore: books lost, backup put into a new store
        _ = try Store.backUp(container, to: folder)
        Store.importLegacyJSON(into: restored.mainContext, folder: folder)   // also over last import's *.imported
        #expect(SalesLog.all(in: restored.mainContext) == sales)   // Decimals, ringUp and autoUnits exact through JSON
        #expect(DayCloseLog.all(in: restored.mainContext) == closes && StockBook.load(from: restored.mainContext)["lays"]?.count == 14)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "sales.json").path(percentEncoded: false)))
    }
}
