goal: improve user experience

## Table of Contents <!-- omit in toc -->

- [1. Guidelines](#1-guidelines)
  - [1.1. Problem 1](#11-problem-1)
  - [1.2. Problem 2](#12-problem-2)
- [2. Definition of Done](#2-definition-of-done)

----------

## 1. Guidelines

The builds this task produces are enumerated from 5.0. Every solved problem is a subversion (doesn't have to happen in order). e.g., once you solve problem 2, then that's 5.0, and once you solve problem 1 afterwards, that's 5.1.

### 1.1. Problem 1

Long scans may cause the device out of space (study the logs to see the details of the issue).

### 1.2. Problem 2

Once the record button is clicked, it then prompts for a name before recording, which is correct. There are two sub-problems
1. once clicked, there's no way to cancel without proceeding, unless i close the app and reopen. there needs to be a cancel option in addition to "later" and "start".
2. even with nothing written, users can still click start, and the effect is the same as later, which is bad design. when nothing is input, the start button should be disabled.

## 2. Definition of Done

All problems listed above solved.
