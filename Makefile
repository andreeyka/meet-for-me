# Владелец файла — архитектор.
.PHONY: test test-core test-mac lint

# Кроссплатформенные модули: собираются в том числе в облачной сессии и на Linux.
test-core:
	swift test --package-path Packages/Core

# Модули, требующие macOS-фреймворков: только на Mac.
test-mac:
	swift test --package-path Packages/Mac

test: test-core test-mac

lint:
	swiftlint --strict
