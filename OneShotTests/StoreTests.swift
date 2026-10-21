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

    @Test func sampleSalesAreRepeatableAndNeverInTheFuture() throws {
        let catalog = Catalog(products: [lays, pocky])
        let count = try SampleSales.fill(catalog: catalog, days: 3, now: t0, in: context)
        let sales = SalesLog.all(in: context)
        #expect(count == sales.count && count > 20)
        #expect(sales.allSatisfy { $0.date <= t0 && !$0.lines.isEmpty })
        #expect(sales.allSatisfy { $0.total == $0.lines.reduce(0) { $0 + $1.amount } })
        #expect(sales.allSatisfy { $0.method == .promptPay || ($0.received ?? 0) >= $0.total })

        let again = try Store.inMemory()
        try SampleSales.fill(catalog: catalog, days: 3, now: t0, in: again.mainContext)
        #expect(SalesLog.all(in: again.mainContext).map(\.total) == sales.map(\.total))   // seeded: same books every demo
    }

    @Test func untrackDeletesOnlyThatRowAndAnEmptyBookDeletesNothing() throws {
        var stock = StockBook(levels: [:])
        stock.set("lays", count: 10, reorderAt: 4)
        stock.set("pocky", count: 3, reorderAt: 1)
        try stock.save(to: context)
        var unloaded = StockBook(levels: [:])
        try unloaded.save(to: context)   // a book that failed to load must not wipe the rows
        #expect(try context.fetchCount(FetchDescriptor<StockRecord>()) == 2)
        stock.untrack("pocky")
        try stock.save(to: context)
        #expect(StockBook.load(from: context)["pocky"] == nil)
        #expect(StockBook.load(from: context)["lays"] == StockLevel(count: 10, reorderAt: 4))
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

        let noShopFiles = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let files = try Store.backUp(container, to: folder, documents: noShopFiles)
        #expect(files.map(\.lastPathComponent) == ["sales.json", "closings.json", "stock.json", "products.json", "barcodes.json"])
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
        _ = try Store.backUp(container, to: folder, documents: noShopFiles)
        Store.importLegacyJSON(into: restored.mainContext, folder: folder)   // also over last import's *.imported
        #expect(SalesLog.all(in: restored.mainContext) == sales)   // Decimals, ringUp and autoUnits exact through JSON
        #expect(DayCloseLog.all(in: restored.mainContext) == closes && StockBook.load(from: restored.mainContext)["lays"]?.count == 14)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "sales.json").path(percentEncoded: false)))
    }

    @Test func restoreBringsBackTheCatalogAndPhotosAndLeavesTheBackupAsItWas() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let shop = temp.appending(path: "shop"), backup = temp.appending(path: "backup"), newShop = temp.appending(path: "new")
        try FileManager.default.createDirectory(at: shop.appending(path: "Crops/pocky"), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: shop.appending(path: "Crops/pocky/1.jpg"))
        try Catalog.saveQuickAdd(lays, in: context)
        try Catalog.saveQuickAdd(pocky, in: context)
        try Catalog.savePrice(25, for: "lays", in: context)
        try Catalog.assignBarcode("885000", to: "pocky", in: context)
        try SalesLog.record([BillLine(product: lays, quantity: 1)], total: 20, method: .cash, received: 20, at: t0, in: context)

        let written = try Store.backUp(container, to: backup, documents: shop)
        #expect(Set(written.map(\.lastPathComponent)) == ["sales.json", "closings.json", "stock.json", "products.json", "barcodes.json", "Crops"])
        #expect(Store.summary(of: backup) == Store.BackupSummary(sales: 1, closes: 0, products: 2, photos: 1))

        // A new device with a product of its own: the backup's catalog replaces it.
        let fresh = try Store.inMemory()
        try Catalog.saveQuickAdd(Product(id: "qa-old", nameEN: "Old", nameTH: "เก่า", price: 5, barcode: nil), in: fresh.mainContext)
        try Store.restore(from: backup, into: fresh.mainContext, documents: newShop)
        #expect(SalesLog.all(in: fresh.mainContext) == SalesLog.all(in: context))
        let restored = Catalog.load(from: fresh.mainContext)
        #expect(restored.products.map(\.id).sorted() == ["lays", "pocky"])
        #expect(restored["lays"]?.price == 25)
        #expect(restored.product(barcode: "885000")?.id == "pocky")
        #expect(FileManager.default.fileExists(atPath: newShop.appending(path: "Crops/pocky/1.jpg").path(percentEncoded: false)))
        // The backup itself is untouched (the imports rename what they read, so restore works on a copy).
        #expect(FileManager.default.fileExists(atPath: backup.appending(path: "sales.json").path(percentEncoded: false)))
        try Store.restore(from: backup, into: fresh.mainContext, documents: newShop)   // twice: nothing doubled
        #expect(SalesLog.all(in: fresh.mainContext).count == 1)
        #expect(Catalog.load(from: fresh.mainContext).products.count == 2)
    }

    /// An install from before V3 keeps its catalog: bundled snacks, taught products, price edits, costs and scanned
    /// barcodes all move from Documents' JSON files into the store, once.
    @Test func legacyCatalogFilesMoveIntoTheStore() throws {
        let docs = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: docs) }
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let taught = Product(id: "qa-1", nameEN: "Pocky", nameTH: "ป๊อกกี้", price: 20, barcode: nil)
        try JSONEncoder().encode([taught]).write(to: docs.appending(path: "quickadd.json"))
        try JSONEncoder().encode(["kitkat-original": Decimal(15)]).write(to: docs.appending(path: "prices.json"))
        try JSONEncoder().encode(["qa-1": Decimal(12)]).write(to: docs.appending(path: "costs.json"))
        try JSONEncoder().encode(["885000": "qa-1"]).write(to: docs.appending(path: "barcodes.json"))

        Catalog.importLegacy(into: context, folder: docs)
        let catalog = Catalog.load(from: context)
        #expect(catalog.products.count == 13)   // the 12 bundled snacks + the taught one
        #expect(catalog["kitkat-original"]?.price == 15)
        #expect(catalog["qa-1"]?.cost == 12)
        #expect(catalog.product(barcode: "885000")?.id == "qa-1")
        #expect(catalog.products.last?.id == "qa-1")   // taught products list last
        #expect(!FileManager.default.fileExists(atPath: docs.appending(path: "quickadd.json").path(percentEncoded: false)))
        Catalog.importLegacy(into: context, folder: docs)   // second launch: nothing doubled
        #expect(Catalog.load(from: context).products.count == 13)
    }

    /// A fresh install starts with no products (onboarding offers the samples); adding them twice adds them once.
    @Test func freshInstallStartsEmptyAndSamplesAddOnce() throws {
        let docs = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docs) }
        Catalog.importLegacy(into: context, folder: docs)
        #expect(Catalog.isEmpty(context))
        try Catalog.addSamples(to: context)
        try Catalog.addSamples(to: context)
        #expect(Catalog.load(from: context).products.count == 12)
    }

    /// Deliveries and recounts become moves for sync; two devices' moves both count.
    @Test func stockChangesBecomeMovesThatAddUp() throws {
        var stock = StockBook(levels: [:])
        stock.set("lays", count: 10, reorderAt: 4)
        stock.receive("lays", 6)
        stock.set("lays", count: 14, reorderAt: 4)   // a recount: 2 missing
        try stock.save(to: context)
        let moves = try context.fetch(FetchDescriptor<StockMoveRecord>(sortBy: [SortDescriptor(\.at)])).map(\.delta)
        #expect(moves.sorted() == [-2, 6, 10])
        stock.applyRemote("lays", delta: 12)   // the other device's delivery
        stock.apply(Sale(id: UUID(), date: t0, lines: [SaleLine(sku: "lays", name: "Lay's", quantity: 3, amount: 60)],
                         total: 60, method: .cash))   // and a sale it made, pulled
        #expect(stock["lays"]?.count == 23)
        try stock.save(to: context)
        #expect(try context.fetchCount(FetchDescriptor<StockMoveRecord>()) == 3)   // remote changes add no moves here
        stock.untrack("lays")
        try stock.save(to: context)
        #expect(try context.fetch(FetchDescriptor<TombstoneRecord>()).map(\.key) == ["lays"])
    }
}
