goal: conclude ablation and improve app

## Table of Contents <!-- omit in toc -->

- [1. Guidelines](#1-guidelines)
- [2. Definition of Done](#2-definition-of-done)
- [3. Future Work](#3-future-work)

----------

## 1. Guidelines

1. lost data:
   1. use avfoundation for front camera, because that's the only choice. use arkit for rear and not use avfoundation, based on ablation results.
2. bad data:
   1. color stream was lossy. this is wrong and must be fixed. why compress? you must never ever compress.
   2. camera focus
3. wrong data:
   1. depth filter is supported for both front and rear camera but neither should turn it on.
   2. per-frame camera intrinsics matching the color and depth frames are not obtainable during data collection. stop exporting those.
4. additional data:
   1. confidence map from arkit for rear camera depth should be recorded.
   2. i want the camera poses be exported when possible as well, just for the sake of making comparisons (do NOT understand as I trust the quality of the camera poses).

## 2. Definition of Done

The above problems fixed in the app, and the app tested and built and installed and you told the user what additional recordings to do and how to do and you wait until the user returns you the data and you verify all changes worked.

## 3. Future Work

1. Figure out how to obtain correct intrinsics that actually matches the color and depth frames.
2. Frame axes data convention issue involving apple's libraries understood and code cleaned up.
3. When and why frames are dropped are understood and code cleaned up.
