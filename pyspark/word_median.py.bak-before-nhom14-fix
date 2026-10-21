"""
Bài 3: Tính giá trị trung vị độ dài các từ (Word Length Median) bằng PySpark
- Thu thập danh sách độ dài từ
- Sắp xếp và lấy giá trị ở vị trí chính giữa
"""
import sys
import re
from pyspark.sql import SparkSession

def main():
    spark = SparkSession.builder \
        .appName("BigData-N14-WordMedian") \
        .getOrCreate()

    sc = spark.sparkContext
    sc.setLogLevel("WARN")

    input_path = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///test_bigdata/input/description.txt"
    print(f"=== Đọc dữ liệu từ đường dẫn: {input_path} ===")

    lines = sc.textFile(input_path)

    # Tách từ và lấy độ dài
    lengths_rdd = lines.flatMap(lambda line: re.split(r'\W+', line.strip())) \
                       .filter(lambda w: len(w) > 0) \
                       .map(lambda w: len(w))

    n = lengths_rdd.count()

    if n == 0:
        print("Không có từ nào trong tập dữ liệu.")
        spark.stop()
        return

    # Sắp xếp phân tán và chỉ collect() tối đa hai phần tử trung tâm.
    middle_indices = {n // 2} if n % 2 == 1 else {(n // 2) - 1, n // 2}
    middle_lengths = (
        lengths_rdd.sortBy(lambda x: x)
        .zipWithIndex()
        .filter(lambda item: item[1] in middle_indices)
        .map(lambda item: item[0])
        .collect()
    )

    if n % 2 == 1:
        median_length = float(middle_lengths[0])
    else:
        median_length = (middle_lengths[0] + middle_lengths[1]) / 2.0

    print("=== KẾT QUẢ TRUNG VỊ ĐỘ DÀI TỪ (WORD LENGTH MEDIAN) ===")
    print(f"Tổng số từ: {n}")
    print(f"Các độ dài trung tâm: {middle_lengths}")
    print(f"Giá trị trung vị (Median): {median_length}")

    spark.stop()

if __name__ == "__main__":
    main()
