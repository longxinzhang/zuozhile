import { GLASS, GLASS_SOFT, INK, LINE_SOFT, MUTED } from '../theme/ZuozhiTheme';

@Component
export struct StatTile {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop color: string = INK;

  build() {
    Column({ space: 8 }) {
      Text(this.label)
        .fontSize(12)
        .fontColor(MUTED)
      Text(this.value)
        .fontSize(28)
        .minFontSize(18)
        .maxFontSize(28)
        .maxLines(1)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.color)
    }
    .height(90)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(GLASS)
    .borderRadius(20)
  }
}

@Component
export struct SmallCounter {
  @Prop label: string = '';
  @Prop value: number = 0;
  @Prop color: string = INK;

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor(MUTED)
      Blank()
      Text(this.value.toString())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.color)
    }
    .height(32)
    .layoutWeight(1)
    .padding({ left: 4, right: 4 })
  }
}

@Component
export struct BaselineTile {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Column({ space: 5 }) {
      Text(this.label)
        .fontSize(12)
        .fontColor(MUTED)
      Text(this.value)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
    }
    .height(68)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(GLASS_SOFT)
    .borderRadius(18)
    .border({ width: 1, color: LINE_SOFT })
  }
}
