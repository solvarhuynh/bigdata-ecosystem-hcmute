"""
Bài 4: Tính độ lệch chuẩn độ dài các từ (Word Length Standard Deviation) bằng PySpark
- Phương sai (Variance) = E[X^2] - (E[X])^2
- Độ lệch chuẩn (Std Dev) = sqrt(Variance)
"""
import sys
import re
import math
from pyspark.sql import SparkSession

def main():
    spark = SparkSession.builder \
        .appName("BigData-N14-WordStdDev") \
        .getOrCreate()

    sc = spark.sparkContext
    sc.setLogLevel("WARN")

    input_path = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///test_bigdata/input/input_text_sample.txt"
    print(f"=== Đọc dữ liệu từ đường dẫn: {input_path} ===")

    lines = sc.textFile(input_path)

    # Tách từ và lấy độ dài
    lengths_rdd = lines.flatMap(lambda line: re.split(r'\W+', line.strip())) \
                       .filter(lambda w: len(w) > 0) \
                       .map(lambda w: len(w))

    # Ánh xạ thành tuple: (len, len^2, 1) để tính tổng song song
    # sum_x, sum_x_squared, count
    stats = lengths_rdd.map(lambda l: (l, l * l, 1)).aggregate(
        (0, 0, 0),
        lambda acc, value: (acc[0] + value[0], acc[1] + value[1], acc[2] + value[2]),
        lambda left, right: (left[0] + right[0], left[1] + right[1], left[2] + right[2]),
    )

    sum_l, sum_sq, n = stats

    if n == 0:
        print("Không có từ nào trong dữ liệu.")
        spark.stop()
        return

    mean = sum_l / float(n)
    variance = (sum_sq / float(n)) - (mean * mean)
    std_dev = math.sqrt(max(0.0, variance))

    print("=== KẾT QUẢ ĐỘ LỆCH CHUẨN ĐỘ DÀI TỪ (WORD LENGTH STD DEV) ===")
    print(f"Tổng số từ (N): {n}")
    print(f"Độ dài trung bình (Mean): {mean:.4f}")
    print(f"Phương sai (Variance): {variance:.4f}")
    print(f"Độ lệch chuẩn (Standard Deviation): {std_dev:.4f}")

    spark.stop()

if __name__ == "__main__":
    main()
