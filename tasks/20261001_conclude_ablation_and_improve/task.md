goal: conclude ablation and improve app

## Table of Contents <!-- omit in toc -->

- [1. Guidelines](#1-guidelines)

----------

## 1. Guidelines

1. use avfoundation for front camera, because that's the only choice. use arkit for rear and not use avfoundation, based on ablation results.
2. depth filter is supported for both front and rear camera but neither should turn it on.
3. confidence map from arkit for rear camera depth should be recorded.
4. color stream was lossy. this is wrong and must be fixed.
