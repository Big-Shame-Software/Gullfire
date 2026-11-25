import Foundation
import Testing
@testable import GullfireKit

/// Tests for the shipped recipe list (Resources/Recipes/recipes.json), read from the repo path.
@Suite("Recipe list")
struct RecipeListTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let recipesURL = root.appendingPathComponent("Resources/Recipes/recipes.json")

    @Test func decodesTheShippedFile() throws {
        let list = try RecipeList.load(Self.recipesURL)
        #expect(list.format == 1)
        #expect(!list.recipes.isEmpty)
    }

    @Test func everyRecipeHasANameAndAUniqueId() throws {
        let list = try RecipeList.load(Self.recipesURL)
        for recipe in list.recipes {
            #expect(!recipe.displayName.trimmingCharacters(in: .whitespaces).isEmpty, "\(recipe.id) has no display name")
        }
        let ids = list.recipes.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func knownFolderGivesItsDisplayName() throws {
        let list = try RecipeList.load(Self.recipesURL)
        let recipe = try #require(list.recipes.first)
        #expect(list.displayName(forFolder: recipe.folder) == recipe.displayName)
    }

    @Test func unknownFolderFallsBackToItsOwnName() throws {
        let list = try RecipeList.load(Self.recipesURL)
        #expect(list.displayName(forFolder: "NoSuchMapFolder") == "NoSuchMapFolder")
    }

    @Test func emptyListFallsBackToTheFolderName() {
        let empty = RecipeList(format: 1, recipes: [])
        #expect(empty.displayName(forFolder: "Anything") == "Anything")
    }

    @Test func shippedFileHasTheFourIdsWithAllFields() throws {
        let list = try RecipeList.load(Self.recipesURL)
        #expect(list.recipes.map(\.id) == ["chicago", "chicagowide", "chicagocity", "cookcounty"])
        let county = try #require(list.recipes.first { $0.id == "cookcounty" })
        #expect(county.folder == "CookCounty")
        #expect(county.downloadMB == 2600)
        #expect(county.diskGB == 9.5)
        #expect(county.freeDiskGB == 24)
        #expect(county.minRamGB == 16)
        #expect(county.buildPeakGB == 6.5)
        #expect(county.approxMinutes == 40)
        #expect(county.outOfCore)
        let chicago = try #require(list.recipes.first { $0.id == "chicago" })
        #expect(!chicago.outOfCore)
        #expect(chicago.minRamGB == 8)
    }

    @Test func canBuildPassesAtTheExactBoundary() throws {
        let list = try RecipeList.load(Self.recipesURL)
        let county = try #require(list.recipes.first { $0.id == "cookcounty" })
        #expect(county.canBuild(memoryGB: 16, freeDiskGB: 24))
        #expect(!county.canBuild(memoryGB: 15.9, freeDiskGB: 24))
        #expect(!county.canBuild(memoryGB: 16, freeDiskGB: 23.9))
        #expect(county.canBuild(memoryGB: 48, freeDiskGB: 500))
    }

    @Test func shortfallNamesWhatIsMissing() throws {
        let list = try RecipeList.load(Self.recipesURL)
        let county = try #require(list.recipes.first { $0.id == "cookcounty" })
        #expect(county.shortfall(memoryGB: 8, freeDiskGB: 100) == "needs 16 GB of memory; this Mac has 8 GB")
        #expect(county.shortfall(memoryGB: 48, freeDiskGB: 10) == "needs 24 GB free disk; this Mac has 10 GB free")
        #expect(county.shortfall(memoryGB: 8, freeDiskGB: 10)
            == "needs 16 GB of memory; this Mac has 8 GB; needs 24 GB free disk; this Mac has 10 GB free")
        #expect(county.shortfall(memoryGB: 16, freeDiskGB: 24) == nil)
    }

    @Test func unknownDiskListsEveryNotInstalledRecipeThatFitsMemory() throws {
        let list = try RecipeList.load(Self.recipesURL)
        let result = list.buildable(memoryGB: 48, freeDiskGB: nil, installedFolders: [])
        #expect(result.diskUnknown)
        #expect(result.recipes == list.recipes)
    }

    @Test func unknownDiskStillHidesRecipesAboveMemory() throws {
        let list = try RecipeList.load(Self.recipesURL)
        let result = list.buildable(memoryGB: 8, freeDiskGB: nil, installedFolders: [])
        #expect(result.diskUnknown)
        #expect(result.recipes.allSatisfy { $0.minRamGB <= 8 })
        #expect(result.recipes == list.recipes.filter { $0.minRamGB <= 8 })
    }

    @Test func knownDiskFiltersAsCanBuild() throws {
        let list = try RecipeList.load(Self.recipesURL)
        let result = list.buildable(memoryGB: 48, freeDiskGB: 10, installedFolders: [])
        #expect(!result.diskUnknown)
        #expect(result.recipes == list.recipes.filter { $0.canBuild(memoryGB: 48, freeDiskGB: 10) })
        #expect(!result.recipes.contains { $0.id == "cookcounty" })
        #expect(result.recipes.contains { $0.id == "chicago" })
    }

    @Test func installedRecipesAreExcludedWithKnownOrUnknownDisk() throws {
        let list = try RecipeList.load(Self.recipesURL)
        let chicago = try #require(list.recipes.first { $0.id == "chicago" })
        let installed: Set<String> = [chicago.folder]
        let unknown = list.buildable(memoryGB: 48, freeDiskGB: nil, installedFolders: installed)
        let known = list.buildable(memoryGB: 48, freeDiskGB: 500, installedFolders: installed)
        #expect(!unknown.recipes.contains { $0.folder == chicago.folder })
        #expect(!known.recipes.contains { $0.folder == chicago.folder })
        #expect(unknown.recipes.count == list.recipes.count - 1)
        #expect(known.recipes.count == list.recipes.count - 1)
    }

    @Test func eightGBMacSeesOnlyRecipesUpToEightGB() throws {
        let list = try RecipeList.load(Self.recipesURL)
        let result = list.buildable(memoryGB: 8, freeDiskGB: 500, installedFolders: [])
        #expect(!result.recipes.isEmpty)
        #expect(result.recipes.allSatisfy { $0.minRamGB <= 8 })
        #expect(!result.recipes.contains { $0.id == "cookcounty" })
    }

    @Test func commandNamesTheScriptAndId() throws {
        let list = try RecipeList.load(Self.recipesURL)
        let chicago = try #require(list.recipes.first { $0.id == "chicago" })
        #expect(chicago.command == "Tools/build_city.sh chicago")
    }
}
