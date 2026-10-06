goal: conclude ablation and improve app

## Table of Contents <!-- omit in toc -->

- [1. Guidelines](#1-guidelines)
- [2. Definition of Done](#2-definition-of-done)
- [3. Future Work](#3-future-work)

----------

## 1. Guidelines

1. lost data:
   1. use avfoundation for front camera and use arkit for rear camera, based on ablation results.
2. bad data:
   1. color stream was lossy. this is wrong and must be fixed. why compress? you must never ever compress.
   2. camera focus: choose autofocus.
3. wrong data:
   1. depth filter is supported for both front and rear camera but neither should turn it on.
   2. make sure per-frame depth intrinsics and depth frame data do match.
4. additional data:
   1. confidence map from arkit for rear camera depth should be recorded.
   2. make sure you export per-frame camera intrinsics for both color and depth.
   3. i want the camera poses be exported when possible as well, just for the sake of making comparisons (do NOT understand as I trust the quality of the camera poses).

## 2. Definition of Done

The above problems fixed in the app, and the app tested and built and installed and you told the user what additional recordings to do and how to do and you wait until the user returns you the data and you verify all changes worked.

## 3. Future Work

1. Frame axes data convention issue involving apple's libraries understood and code cleaned up.
2. When and why frames are dropped are understood and code cleaned up.
