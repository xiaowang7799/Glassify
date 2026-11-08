DEBUG ?= 0
FINALPACKAGE ?= 1
ARCHS = arm64 arm64e

# The merged notification engine needs iOS 15, so every scheme targets 15.0.
TARGET = iphone:clang:16.5:15.0
