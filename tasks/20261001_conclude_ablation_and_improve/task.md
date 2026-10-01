goal: conclude ablation and improve app

## Table of Contents <!-- omit in toc -->

- [1. Guidelines](#1-guidelines)

----------

## 1. Guidelines

1. loss of data:
   1. use avfoundation for front camera, because that's the only choice. use arkit for rear and not use avfoundation, based on ablation results.
   2. depth filter is supported for both front and rear camera but neither should turn it on.
   3. color stream was lossy. this is wrong and must be fixed.
2. additional data:
   1. confidence map from arkit for rear camera depth should be recorded.
   2. i want the camera poses be exported when possible as well, just for the sake of making comparisons (do NOT understand as I trust the quality of the camera poses).
