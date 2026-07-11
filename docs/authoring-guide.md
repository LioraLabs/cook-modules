# Authoring a Cook module

This guide is a non-normative companion to the Cook Standard's **§12.7
Module-authoring contract** (`#mods.authoring`). It walks through how to
build a Cook module in practice — worked examples and patterns drawn from
the real `cook_cc` and `cook_pnpm` modules in this repo — but it does not
own any rule. Where this guide and the Standard disagree, the Standard
wins; every rule stated here cites the §-section that governs it.

## How to read this guide

Read Standard §12 (Modules) first for the module lifecycle — phases, the
register/execute split, the API chapters a module is built from — then
come back here for the how-to. Keep §12.7 open alongside this guide as
you work: each section below points back to the subsection of §12.7 (or
the adjacent §22 field reference) that it is illustrating.

## Contents

1. [What a module is and when its code runs](#1-what-a-module-is-and-when-its-code-runs)
2. [Anatomy of a module on disk](#2-anatomy-of-a-module-on-disk)
3. [Registering work units with `cook.add_unit`](#3-registering-work-units-with-cookadd_unit)
4. [Registering probes](#4-registering-probes)
5. [Reading probe values and dependency outputs](#5-reading-probe-values-and-dependency-outputs)
6. [Seals and sharing dispositions](#6-seals-and-sharing-dispositions)
7. [Probe-key naming](#7-probe-key-naming)
8. [Cross-module patterns](#8-cross-module-patterns)
9. [Testing with the `cook_stub` double](#9-testing-with-the-cook_stub-double)
10. [Publishing a blessed module](#10-publishing-a-blessed-module)
11. [New-module checklist](#11-new-module-checklist)

## 1. What a module is and when its code runs

## 2. Anatomy of a module on disk

## 3. Registering work units with `cook.add_unit`

## 4. Registering probes

## 5. Reading probe values and dependency outputs

## 6. Seals and sharing dispositions

## 7. Probe-key naming

## 8. Cross-module patterns

## 9. Testing with the `cook_stub` double

## 10. Publishing a blessed module

## 11. New-module checklist
