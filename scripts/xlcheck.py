# -*- coding: utf-8 -*-
import openpyxl
xl = r'E:\LRN-Data\CodingMaster\CodingMasterFiles\PCRLabsofAmerica\ReportsOutput\2026\02.February\02.26.2026 - 03.04.2026\20260316R0215_PCRLabsofAmerica_CodingValidated_02.26.2026 - 03.04.2026.xlsx'
wb = openpyxl.load_workbook(xl, read_only=True, data_only=True)
ws = wb['Financial Dashboard']
for i, row in enumerate(ws.iter_rows(min_row=1, max_row=200, values_only=True), 1):
    vals = [v for v in row if v is not None]
    if vals:
        print(f'  row {i:3d}: {vals}')
wb.close()